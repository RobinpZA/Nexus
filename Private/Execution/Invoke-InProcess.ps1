function Send-ProcessRequest {
    <#
    .SYNOPSIS
        Writes a request to a process context's command channel.
    .DESCRIPTION
        Restarts the child process first if it has died. Returns the (possibly new)
        context entry, or $null when the process could not be restarted.
    .PARAMETER ProcessEntry
        The process context entry.
    .PARAMETER ModuleEntry
        The registry entry, used to recreate the context if needed.
    .PARAMETER Request
        The request payload written as command.json.
    .EXAMPLE
        $ctx = Send-ProcessRequest -ProcessEntry $p -ModuleEntry $mod -Request @{ command = 'Get-Thing'; parameters = @{} }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ProcessEntry,
        [Parameter(Mandatory)][object]$ModuleEntry,
        [Parameter(Mandatory)][hashtable]$Request
    )

    $proc = $ProcessEntry.Process
    if (-not $proc -or $proc.HasExited) {
        Write-HubLog -Level Warning -Message "Process dead for $($ModuleEntry.name) — recreating"
        $script:ModuleRunspaces.Remove($ModuleEntry.name)
        $ProcessEntry = Get-ModuleRunspace -ModuleEntry $ModuleEntry -Force
        if (-not $ProcessEntry -or -not $ProcessEntry.Process) { return $null }
    }

    # Drop a stale response from a previous, abandoned request.
    if (Test-Path $ProcessEntry.ResponseFile) { Remove-Item $ProcessEntry.ResponseFile -Force -ErrorAction SilentlyContinue }

    Write-AtomicFile -Path $ProcessEntry.CommandFile -Value ($Request | ConvertTo-Json -Compress -Depth 5)
    return $ProcessEntry
}

function Receive-ProcessResponse {
    <#
    .SYNOPSIS
        Reads a completed response from a process context, if one is ready.
    .DESCRIPTION
        Returns $null while the response file is absent or still being written — the
        caller polls again rather than blocking.
    .PARAMETER ProcessEntry
        The process context entry.
    .EXAMPLE
        $response = Receive-ProcessResponse -ProcessEntry $ctx
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ProcessEntry)

    if (-not (Test-Path $ProcessEntry.ResponseFile)) { return $null }

    try {
        $raw = Get-Content $ProcessEntry.ResponseFile -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $parsed = $raw | ConvertFrom-Json
    } catch {
        # Locked or half-written — try again on the next poll.
        return $null
    }

    Remove-Item $ProcessEntry.ResponseFile -Force -ErrorAction SilentlyContinue
    return $parsed
}

function ConvertFrom-ProcessResponse {
    <#
    .SYNOPSIS
        Converts a worker response into the standard command result object.
    .PARAMETER Response
        The parsed response from the child process.
    .PARAMETER ModuleName
        The module the command belongs to.
    .PARAMETER CommandName
        The command that ran.
    .PARAMETER DurationMs
        Fallback duration when the worker did not report one.
    .EXAMPLE
        ConvertFrom-ProcessResponse -Response $r -ModuleName 'Graph' -CommandName 'Get-Thing' -DurationMs 120
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Response,
        [Parameter(Mandatory)][string]$ModuleName,
        [Parameter(Mandatory)][string]$CommandName,
        [int]$DurationMs = 0
    )

    $output = @($Response.output | Where-Object { $_ } | ForEach-Object {
        $line = [PSCustomObject]@{ stream = $_.stream; message = $_.message }
        if ($_.data) { $line | Add-Member -NotePropertyName data -NotePropertyValue $_.data }
        $line
    })

    $duration = if ($Response.durationMs) { [int]$Response.durationMs } else { $DurationMs }

    return [PSCustomObject]@{
        success = [bool]$Response.success; module = $ModuleName; command = $CommandName
        durationMs = $duration; output = $output
    }
}

function Update-ProcessConnectionState {
    <#
    .SYNOPSIS
        Tracks whether a process context holds an authenticated session.
    .PARAMETER ProcessEntry
        The process context entry.
    .PARAMETER CommandName
        The command that just completed.
    .PARAMETER Success
        Whether it succeeded.
    .EXAMPLE
        Update-ProcessConnectionState -ProcessEntry $ctx -CommandName 'Connect-MgGraph' -Success $true
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ProcessEntry,
        [Parameter(Mandatory)][string]$CommandName,
        [bool]$Success
    )

    $verb = Get-CommandVerb -CommandName $CommandName
    if ($verb -eq 'Connect' -and $Success) { $ProcessEntry.Connected = $true }
    if ($verb -eq 'Disconnect') { $ProcessEntry.Connected = $false }
    $ProcessEntry.LastUsed = Get-Date
}

function Start-ProcessAsync {
    <#
    .SYNOPSIS
        Sends a command to a child process and returns a job id immediately.
    .DESCRIPTION
        The listener stays responsive: Get-BackgroundCommandResult picks the response up
        on a later poll instead of this function waiting on the command channel.
    .PARAMETER ProcessEntry
        The process context entry.
    .PARAMETER CommandName
        The command to run.
    .PARAMETER Parameters
        Parameters to bind.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .EXAMPLE
        Start-ProcessAsync -ProcessEntry $ctx -CommandName 'Get-Thing' -Parameters @{} -ModuleEntry $mod
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ProcessEntry,
        [Parameter(Mandatory)][string]$CommandName,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory)][object]$ModuleEntry
    )

    if (-not $script:BackgroundJobs) { $script:BackgroundJobs = @{} }

    $activeJobId = Get-ActiveContextJob -ContextEntry $ProcessEntry
    if ($activeJobId) { return New-ContextBusyResult -ModuleName $ModuleEntry.name -CommandName $CommandName -ActiveJobId $activeJobId }

    Remove-CompletedJob

    $ProcessEntry = Send-ProcessRequest -ProcessEntry $ProcessEntry -ModuleEntry $ModuleEntry -Request @{
        command = $CommandName; parameters = $Parameters
    }
    if (-not $ProcessEntry) {
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = 'Failed to restart process' })
        }
    }

    $jobId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $script:BackgroundJobs[$jobId] = @{
        Id = $jobId; Module = $ModuleEntry.name; Command = $CommandName; Mode = 'process'
        Context = $ProcessEntry; StartedAt = Get-Date; TimeoutAt = (Get-Date).AddMinutes(10)
        Status = 'running'; Result = $null
    }
    $ProcessEntry.ActiveAsyncJobId = $jobId
    $ProcessEntry.LastUsed = Get-Date

    Write-HubLog -Level Info -Message "Async job: $jobId ($($ModuleEntry.name)/$CommandName) in process PID $($ProcessEntry.Process.Id)"
    return $jobId
}

function Invoke-InProcess {
    <#
    .SYNOPSIS
        Sends a command to a child process and waits for the response.
    .DESCRIPTION
        Blocking variant, used by callers that are not driving a job poll loop.
        The portal always uses Start-ProcessAsync instead.
    .PARAMETER ProcessEntry
        The process context entry.
    .PARAMETER CommandName
        The command to run.
    .PARAMETER Parameters
        Parameters to bind.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .PARAMETER TimeoutMinutes
        How long to wait for a response.
    .EXAMPLE
        Invoke-InProcess -ProcessEntry $ctx -CommandName 'Get-Thing' -Parameters @{} -ModuleEntry $mod
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ProcessEntry,
        [Parameter(Mandatory)][string]$CommandName,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory)][object]$ModuleEntry,
        [int]$TimeoutMinutes = 10
    )

    $activeJobId = Get-ActiveContextJob -ContextEntry $ProcessEntry
    if ($activeJobId) { return New-ContextBusyResult -ModuleName $ModuleEntry.name -CommandName $CommandName -ActiveJobId $activeJobId }

    $startTime = Get-Date

    $ProcessEntry = Send-ProcessRequest -ProcessEntry $ProcessEntry -ModuleEntry $ModuleEntry -Request @{
        command = $CommandName; parameters = $Parameters
    }
    if (-not $ProcessEntry) {
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = 'Failed to restart process' })
        }
    }

    Write-HubLog -Level Info -Message "Executing in process (PID $($ProcessEntry.Process.Id)): $CommandName" -Source $ModuleEntry.name

    $timeout = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $timeout) {
        if ($ProcessEntry.Process.HasExited) {
            return [PSCustomObject]@{
                success = $false; module = $ModuleEntry.name; command = $CommandName
                durationMs = [math]::Round(((Get-Date) - $startTime).TotalMilliseconds, 0)
                output = @([PSCustomObject]@{ stream = 'Error'; message = 'Process exited unexpectedly' })
            }
        }

        $response = Receive-ProcessResponse -ProcessEntry $ProcessEntry
        if ($response) {
            $result = ConvertFrom-ProcessResponse -Response $response -ModuleName $ModuleEntry.name -CommandName $CommandName `
                -DurationMs ([math]::Round(((Get-Date) - $startTime).TotalMilliseconds, 0))
            Update-ProcessConnectionState -ProcessEntry $ProcessEntry -CommandName $CommandName -Success $result.success
            return $result
        }

        Start-Sleep -Milliseconds 200
    }

    return [PSCustomObject]@{
        success = $false; module = $ModuleEntry.name; command = $CommandName
        durationMs = [math]::Round(((Get-Date) - $startTime).TotalMilliseconds, 0)
        output = @([PSCustomObject]@{ stream = 'Error'; message = 'No response from process (timeout)' })
    }
}
