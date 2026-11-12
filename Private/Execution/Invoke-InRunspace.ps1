function Invoke-InRunspace {
    <#
    .SYNOPSIS
        Runs a command in the module's isolated context (runspace or child process).
    .DESCRIPTION
        Returns a job id string when the command was started asynchronously, or a result
        object when it ran synchronously or could not be started.

        Connect/Disconnect commands go through the same async path as everything else,
        for both runspace and process contexts. That used to be process-only: a runspace
        connect ran synchronously on the theory that it might raise an interactive auth
        prompt inside the Nexus process, which the caller would then have to block and
        wait for. Empirically that prompt never happens — a runspace built by
        New-RunspaceContext gets PowerShell's internal "Default Host", not the real
        console: Read-Host fails immediately there every time ("the host program does not
        support user interaction"), synchronous or not, and Write-Host/Information output
        is only ever collected once the whole pipeline finishes in both paths — there is
        no live prompt to actually wait for. Real interactive connects (Graph/EXO/Teams)
        already run in process isolation, unconditionally async since the ten-minute-freeze
        fix below. Keeping runspace connects synchronous only meant a lightweight custom
        module's Connect-* command could freeze the entire single-threaded listener —
        including /api/health — for as long as that command ran.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .PARAMETER CommandName
        The command to run. Callers must have checked it against the module's exports.
    .PARAMETER Parameters
        Parameters to bind, as supplied by the client.
    .PARAMETER Async
        Request non-blocking execution.
    .EXAMPLE
        Invoke-InRunspace -ModuleEntry $mod -CommandName 'Get-Thing' -Parameters @{} -Async
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [Parameter(Mandatory)][string]$CommandName,
        [hashtable]$Parameters = @{},
        [switch]$Async
    )

    try { $rsEntry = Get-ModuleRunspace -ModuleEntry $ModuleEntry }
    catch {
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = $_.Exception.Message })
        }
    }
    if (-not $rsEntry) {
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = "Failed to create context for: $($ModuleEntry.name)" })
        }
    }

    if ($rsEntry.Mode -eq 'process') {
        if ($Async) { return Start-ProcessAsync -ProcessEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry }
        return Invoke-InProcess -ProcessEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry
    }

    if ($Async) { return Start-RunspaceAsync -RsEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry }
    return Invoke-RunspaceSync -RsEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry
}

function Get-CommandVerb {
    <#
    .SYNOPSIS
        Returns the verb of a Verb-Noun command name, or $null.
    .PARAMETER CommandName
        The command name to inspect.
    .EXAMPLE
        Get-CommandVerb -CommandName 'Connect-MgGraph'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandName)

    if ($CommandName -match '^([A-Za-z]+)-') { return $Matches[1] }
    return $null
}

function Get-ActiveContextJob {
    <#
    .SYNOPSIS
        Returns the id of the job currently occupying a context, or $null.
    .DESCRIPTION
        A runspace runs one pipeline at a time and a process context has a single
        command channel, so both are gated the same way. A cancelled or timed-out
        runspace job still occupies its context until its stop is reaped
        (StopRequestedAt set, StopReaped not): the old pipeline is still running there,
        so nothing else may Invoke() on that runspace. Reaping is attempted here too.
        Stale pointers left by a finished job are cleared here.
    .PARAMETER ContextEntry
        The runspace or process context entry.
    .EXAMPLE
        $busy = Get-ActiveContextJob -ContextEntry $rsEntry
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ContextEntry)

    if (-not $ContextEntry.ActiveAsyncJobId) { return $null }

    $activeJobId = [string]$ContextEntry.ActiveAsyncJobId
    if ($script:BackgroundJobs -and $script:BackgroundJobs.ContainsKey($activeJobId)) {
        $activeJob = $script:BackgroundJobs[$activeJobId]
        if ($activeJob.Status -eq 'running') { return $activeJobId }
        if ($activeJob.StopRequestedAt -and -not $activeJob.StopReaped) {
            Complete-PendingStop -Job $activeJob
            if (-not $activeJob.StopReaped) { return $activeJobId }
            if (-not $ContextEntry.ActiveAsyncJobId) { return $null }
        }
    }

    $ContextEntry.ActiveAsyncJobId = $null
    return $null
}

function New-ContextBusyResult {
    <#
    .SYNOPSIS
        Builds the result returned when a module context is already in use.
    .PARAMETER ModuleName
        The module being addressed.
    .PARAMETER CommandName
        The command that could not start.
    .PARAMETER ActiveJobId
        The job already running in that context.
    .EXAMPLE
        New-ContextBusyResult -ModuleName 'Graph' -CommandName 'Get-Thing' -ActiveJobId 'ab12'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModuleName,
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$ActiveJobId
    )

    return [PSCustomObject]@{
        success = $false; module = $ModuleName; command = $CommandName; durationMs = 0
        output = @([PSCustomObject]@{
            stream  = 'Error'
            message = "Module '$ModuleName' already has a running command (jobId: $ActiveJobId)"
        })
    }
}

function Get-RunspaceInvokeScript {
    <#
    .SYNOPSIS
        Returns the script used to invoke a command inside a module runspace.
    .DESCRIPTION
        SECURITY: The command name and parameters are passed as ARGUMENTS, never
        concatenated into the script text. Building a command line from request data
        let a crafted parameter name or array value run arbitrary code alongside the
        allow-listed command. Parameter names are also checked against the command's
        real parameter set before splatting.

        SECURITY: Get-Command is scoped to the target module (-Module $ModuleName).
        The runspace is created with CreateDefault(), so every built-in cmdlet
        (Remove-Item, Invoke-Expression, ...) is already loaded in it. The caller's
        allow-list check at the API layer only blocks a command it can positively
        identify from the manifest — a module declaring `FunctionsToExport = '*'`
        (a common pattern) yields an empty list there and nothing is blocked. Scoping
        the lookup here means only commands this module actually exports can ever be
        resolved, independent of what the manifest claims.
    .EXAMPLE
        $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument($CommandName).AddArgument($Parameters).AddArgument((Get-ModuleScopeName -ModuleEntry $mod))
    #>
    [CmdletBinding()]
    param()

    # The binder and the output shaper are this module's own function text, not request
    # data, so embedding them keeps the one-binder rule without widening what the script
    # trusts. Shaping inside the runspace keeps that work off the listener thread.
    $embedded = foreach ($name in 'ConvertTo-BoundParameter', 'ConvertTo-HubOutput', 'ConvertTo-HubOutputData', 'ConvertTo-HubCellValue') {
        "function $name {`n$((Get-Item -LiteralPath "function:$name").ScriptBlock)`n}"
    }

    return 'param($CommandName, $Params, $ModuleName, $MaxRows, $Summary)' + "`n`n" + ($embedded -join "`n") + "`n" + @'

# Get-Command treats -Module $null/'' as "no filter", not "match nothing" — an absent
# ModuleName would silently reopen the exact hole this scoping exists to close.
if ([string]::IsNullOrWhiteSpace($ModuleName)) { throw 'Internal error: no module scope supplied.' }

$cmd = Get-Command -Name $CommandName -Module $ModuleName -ErrorAction SilentlyContinue
if (-not $cmd) { throw "Command '$CommandName' is not exported by module '$ModuleName'." }

$bound = ConvertTo-BoundParameter -Command $cmd -Parameters $Params

# Records are shaped (and capped) one at a time as they are produced, into the caller's
# output collection, so everything emitted before a terminating error or a cancel survives.
try {
    & $cmd @bound *>&1 | ForEach-Object {
        ConvertTo-HubOutput -Records (, $_) -MaxRows $MaxRows -Summary $Summary
    }
} catch {
    ConvertTo-HubOutput -Records (, $_)
}
'@
}

function Get-RunspaceCommandOutput {
    <#
    .SYNOPSIS
        Builds the output object for a runspace command from its collected, already shaped records.
    .PARAMETER Output
        The PSDataCollection the invoke script wrote shaped records into. May be $null.
    .PARAMETER Summary
        The shared hashtable ConvertTo-HubOutput filled in (Total, Kept, Truncated).
    .PARAMETER ErrorMessage
        An error raised outside the script's own try/catch (command not exported, host
        failure). Appended as an Error record.
    .EXAMPLE
        $r = Get-RunspaceCommandOutput -Output $job.Output -Summary $job.Summary
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Output,
        [AllowNull()][hashtable]$Summary,
        [string]$ErrorMessage
    )

    $records = [System.Collections.Generic.List[object]]::new()
    if ($Output) {
        # Index, don't enumerate: enumerating a PSDataCollection that is still being
        # written to blocks until the pipeline completes it.
        $count = $Output.Count
        for ($i = 0; $i -lt $count; $i++) {
            $item = $Output[$i]
            if ($null -ne $item) { $records.Add($item) }
        }
    }
    if ($ErrorMessage) { $records.Add([PSCustomObject]@{ stream = 'Error'; message = $ErrorMessage }) }

    $total = if ($Summary -and $Summary.ContainsKey('Total')) { [int]$Summary['Total'] } else { 0 }
    return [PSCustomObject]@{
        output     = $records
        success    = -not ($records | Where-Object { $_.stream -eq 'Error' })
        truncated  = [bool]($Summary -and $Summary['Truncated'])
        totalCount = [math]::Max($total, @($records | Where-Object { $_.stream -ne 'Error' }).Count)
    }
}

function New-RunspaceInvocation {
    <#
    .SYNOPSIS
        Creates a PowerShell instance loaded with the invoke script, plus the collections it fills.
    .PARAMETER RsEntry
        The runspace context entry.
    .PARAMETER CommandName
        The command to run.
    .PARAMETER Parameters
        Parameters to bind.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .EXAMPLE
        $inv = New-RunspaceInvocation -RsEntry $rs -CommandName 'Get-Thing' -Parameters @{} -ModuleEntry $mod
    #>
    [CmdletBinding()]
    param([object]$RsEntry, [string]$CommandName, [hashtable]$Parameters, [object]$ModuleEntry)

    $summary = [hashtable]::Synchronized(@{ Total = 0; Kept = 0; Truncated = $false })
    $ps = [PowerShell]::Create()
    $ps.Runspace = $RsEntry.Runspace
    $null = $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument($CommandName).AddArgument($Parameters).
        AddArgument((Get-ModuleScopeName -ModuleEntry $ModuleEntry)).AddArgument((Get-MaxOutputRow)).AddArgument($summary)

    $inputs = [System.Management.Automation.PSDataCollection[psobject]]::new()
    $inputs.Complete()
    return @{
        PowerShell = $ps; Summary = $summary; Inputs = $inputs
        Output = [System.Management.Automation.PSDataCollection[psobject]]::new()
    }
}

function Invoke-RunspaceSync {
    param([object]$RsEntry, [string]$CommandName, [hashtable]$Parameters, [object]$ModuleEntry)

    $activeJobId = Get-ActiveContextJob -ContextEntry $RsEntry
    if ($activeJobId) { return New-ContextBusyResult -ModuleName $ModuleEntry.name -CommandName $CommandName -ActiveJobId $activeJobId }

    $startTime = Get-Date

    $inv = New-RunspaceInvocation -RsEntry $RsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry
    $ps = $inv.PowerShell

    Write-HubLog -Level Info -Message "Executing in runspace (sync): $CommandName" -Source $ModuleEntry.name
    $errorMessage = $null
    try {
        # Output streams into $inv.Output, so records produced before a terminating
        # error are still there when Invoke throws.
        $null = $ps.Invoke($inv.Inputs, $inv.Output)
    } catch {
        $errorMessage = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
    } finally { $ps.Dispose() }

    $built = Get-RunspaceCommandOutput -Output $inv.Output -Summary $inv.Summary -ErrorMessage $errorMessage
    $verb = Get-CommandVerb -CommandName $CommandName
    if ($verb -eq 'Connect' -and $built.success) { $RsEntry.Connected = $true }
    if ($verb -eq 'Disconnect') { $RsEntry.Connected = $false }

    $RsEntry.LastUsed = Get-Date
    $duration = ((Get-Date) - $startTime).TotalMilliseconds
    return [PSCustomObject]@{
        success = $built.success; module = $ModuleEntry.name; command = $CommandName
        durationMs = [math]::Round($duration, 0); output = @($built.output)
        truncated = $built.truncated; totalCount = $built.totalCount
    }
}

function Start-RunspaceAsync {
    param([object]$RsEntry, [string]$CommandName, [hashtable]$Parameters, [object]$ModuleEntry)

    if (-not $script:BackgroundJobs) { $script:BackgroundJobs = @{} }

    $activeJobId = Get-ActiveContextJob -ContextEntry $RsEntry
    if ($activeJobId) { return New-ContextBusyResult -ModuleName $ModuleEntry.name -CommandName $CommandName -ActiveJobId $activeJobId }

    Remove-CompletedJob

    $jobId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $inv = $null

    try {
        $inv = New-RunspaceInvocation -RsEntry $RsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry
        $asyncResult = $inv.PowerShell.BeginInvoke($inv.Inputs, $inv.Output)
    } catch {
        if ($inv) { $inv.PowerShell.Dispose() }
        return [PSCustomObject]@{
            success = $false
            module = $ModuleEntry.name
            command = $CommandName
            durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = $_.Exception.Message })
        }
    }

    $script:BackgroundJobs[$jobId] = @{
        Id = $jobId; Module = $ModuleEntry.name; Command = $CommandName; Mode = 'runspace'
        PowerShell = $inv.PowerShell; AsyncResult = $asyncResult; StartedAt = Get-Date
        Output = $inv.Output; Summary = $inv.Summary
        TimeoutAt = (Get-Date).AddMinutes(10)
        Status = 'running'; Result = $null; Context = $RsEntry
    }
    $RsEntry.ActiveAsyncJobId = $jobId
    $RsEntry.LastUsed = Get-Date
    Write-HubLog -Level Info -Message "Async job: $jobId ($($ModuleEntry.name)/$CommandName)"
    return $jobId
}
