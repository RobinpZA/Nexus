function Invoke-InRunspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [Parameter(Mandatory)][string]$CommandName,
        [hashtable]$Parameters = @{},
        [switch]$Async
    )

    $rsEntry = Get-ModuleRunspace -ModuleEntry $ModuleEntry
    if (-not $rsEntry) {
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = "Failed to create context for: $($ModuleEntry.name)" })
        }
    }

    if ($rsEntry.Mode -eq 'process') {
        # Process mode: always sync from Nexus's perspective (the process handles it)
        return Invoke-InProcess -ProcessEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry
    } else {
        if ($Async) {
            return Start-RunspaceAsync -RsEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry
        } else {
            return Invoke-RunspaceSync -RsEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry
        }
    }
}

function Invoke-InProcess {
    <#
    .SYNOPSIS
        Sends a command to a child process via file-based JSON communication.
        Writes command.json, polls for response.json.
    #>
    param([object]$ProcessEntry, [string]$CommandName, [hashtable]$Parameters, [object]$ModuleEntry)

    $startTime = Get-Date
    $proc = $ProcessEntry.Process

    if (-not $proc -or $proc.HasExited) {
        Write-HubLog -Level Warning -Message "Process dead for $($ModuleEntry.name) — recreating"
        $script:ModuleRunspaces.Remove($ModuleEntry.name)
        $ProcessEntry = Get-ModuleRunspace -ModuleEntry $ModuleEntry -Force
        if (-not $ProcessEntry -or -not $ProcessEntry.Process) {
            return [PSCustomObject]@{
                success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
                output = @([PSCustomObject]@{ stream = 'Error'; message = "Failed to restart process" })
            }
        }
        $proc = $ProcessEntry.Process
    }

    Write-HubLog -Level Info -Message "Executing in process (PID $($proc.Id)): $CommandName" -Source $ModuleEntry.name

    $commandFile  = $ProcessEntry.CommandFile
    $responseFile = $ProcessEntry.ResponseFile

    # Clean up any stale response file
    if (Test-Path $responseFile) { Remove-Item $responseFile -Force -ErrorAction SilentlyContinue }

    # Write command
    $request = @{ command = $CommandName; parameters = $Parameters } | ConvertTo-Json -Compress -Depth 5
    $request | Out-File $commandFile -Encoding utf8 -Force

    # Poll for response
    $timeout = [DateTime]::Now.AddMinutes(10)
    $responseLine = $null

    while ([DateTime]::Now -lt $timeout) {
        if ($proc.HasExited) {
            $duration = ((Get-Date) - $startTime).TotalMilliseconds
            return [PSCustomObject]@{
                success = $false; module = $ModuleEntry.name; command = $CommandName
                durationMs = [math]::Round($duration, 0)
                output = @([PSCustomObject]@{ stream = 'Error'; message = 'Process exited unexpectedly' })
            }
        }

        if (Test-Path $responseFile) {
            Start-Sleep -Milliseconds 100  # Brief pause to ensure file is fully written
            try {
                $responseLine = Get-Content $responseFile -Raw -Encoding utf8
                Remove-Item $responseFile -Force -ErrorAction SilentlyContinue
                break
            } catch {
                # File might be locked — retry
                Start-Sleep -Milliseconds 200
            }
        }
        Start-Sleep -Milliseconds 200
    }

    if (-not $responseLine) {
        $duration = ((Get-Date) - $startTime).TotalMilliseconds
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName
            durationMs = [math]::Round($duration, 0)
            output = @([PSCustomObject]@{ stream = 'Error'; message = 'No response from process (timeout)' })
        }
    }

    try {
        $result = $responseLine | ConvertFrom-Json
    } catch {
        $duration = ((Get-Date) - $startTime).TotalMilliseconds
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName
            durationMs = [math]::Round($duration, 0)
            output = @([PSCustomObject]@{ stream = 'Error'; message = "Invalid response from process: $($_.Exception.Message)" })
        }
    }

    $verb = if ($CommandName -match '^([A-Za-z]+)-') { $Matches[1] } else { $null }
    if ($verb -eq 'Connect' -and $result.success) { $ProcessEntry.Connected = $true }
    if ($verb -eq 'Disconnect') { $ProcessEntry.Connected = $false }
    $ProcessEntry.LastUsed = Get-Date

    $output = @($result.output | ForEach-Object { [PSCustomObject]@{ stream = $_.stream; message = $_.message } })
    return [PSCustomObject]@{
        success = [bool]$result.success; module = $ModuleEntry.name; command = $CommandName
        durationMs = [int]$result.durationMs; output = $output
    }
}

function Invoke-RunspaceSync {
    param([object]$RsEntry, [string]$CommandName, [hashtable]$Parameters, [object]$ModuleEntry)

    $startTime = Get-Date
    $paramBlock = ''
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [bool] -or $value -eq 'True' -or $value -eq 'true') { $paramBlock += " -$key" }
        elseif ($value -is [string]) { $paramBlock += " -$key '$($value -replace "'","''")'" }
        else { $paramBlock += " -$key $value" }
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $RsEntry.Runspace
    $ps.AddScript("$CommandName$paramBlock *>&1") | Out-Null

    Write-HubLog -Level Info -Message "Executing in runspace (sync): $CommandName" -Source $ModuleEntry.name
    $output = @()
    try {
        $results = $ps.Invoke()
        foreach ($item in $results) { $output += [PSCustomObject]@{ stream = 'Success'; message = $item.ToString() } }
        foreach ($err in $ps.Streams.Error) { $output += [PSCustomObject]@{ stream = 'Error'; message = $err.ToString() } }
        foreach ($warn in $ps.Streams.Warning) { $output += [PSCustomObject]@{ stream = 'Warning'; message = $warn.ToString() } }
        foreach ($info in $ps.Streams.Information) { $output += [PSCustomObject]@{ stream = 'Information'; message = $info.ToString() } }
        $success = $ps.Streams.Error.Count -eq 0
        $verb = if ($CommandName -match '^([A-Za-z]+)-') { $Matches[1] } else { $null }
        if ($verb -eq 'Connect' -and $success) { $RsEntry.Connected = $true }
        if ($verb -eq 'Disconnect') { $RsEntry.Connected = $false }
    } catch {
        $output += [PSCustomObject]@{ stream = 'Error'; message = $_.Exception.Message }
        $success = $false
    } finally { $ps.Dispose() }

    $RsEntry.LastUsed = Get-Date
    $duration = ((Get-Date) - $startTime).TotalMilliseconds
    return [PSCustomObject]@{
        success = $success; module = $ModuleEntry.name; command = $CommandName
        durationMs = [math]::Round($duration, 0); output = $output
    }
}

function Start-RunspaceAsync {
    param([object]$RsEntry, [string]$CommandName, [hashtable]$Parameters, [object]$ModuleEntry)

    if (-not $script:BackgroundJobs) { $script:BackgroundJobs = @{} }

    # A runspace can only execute one active pipeline at a time.
    # Gate async requests per module to avoid BeginInvoke collisions.
    if ($RsEntry.ActiveAsyncJobId) {
        $activeJobId = [string]$RsEntry.ActiveAsyncJobId
        if ($script:BackgroundJobs.ContainsKey($activeJobId) -and $script:BackgroundJobs[$activeJobId].Status -eq 'running') {
            return [PSCustomObject]@{
                success = $false
                module = $ModuleEntry.name
                command = $CommandName
                durationMs = 0
                output = @([PSCustomObject]@{
                    stream = 'Error'
                    message = "Module '$($ModuleEntry.name)' already has a running async command (jobId: $activeJobId)"
                })
            }
        }

        # Stale pointer from a previously completed job.
        $RsEntry.ActiveAsyncJobId = $null
    }

    $paramBlock = ''
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [bool] -or $value -eq 'True' -or $value -eq 'true') { $paramBlock += " -$key" }
        elseif ($value -is [string]) { $paramBlock += " -$key '$($value -replace "'","''")'" }
        else { $paramBlock += " -$key $value" }
    }

    $jobId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $ps = [PowerShell]::Create()
    $ps.Runspace = $RsEntry.Runspace

    try {
        $ps.AddScript("$CommandName$paramBlock *>&1") | Out-Null
        $asyncResult = $ps.BeginInvoke()
    } catch {
        $ps.Dispose()
        return [PSCustomObject]@{
            success = $false
            module = $ModuleEntry.name
            command = $CommandName
            durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = $_.Exception.Message })
        }
    }

    $script:BackgroundJobs[$jobId] = @{
        Id = $jobId; Module = $ModuleEntry.name; Command = $CommandName
        PowerShell = $ps; AsyncResult = $asyncResult; StartedAt = Get-Date
        Status = 'running'; Result = $null
    }
    $RsEntry.ActiveAsyncJobId = $jobId
    $RsEntry.LastUsed = Get-Date
    Write-HubLog -Level Info -Message "Async job: $jobId ($($ModuleEntry.name)/$CommandName)"
    return $jobId
}
