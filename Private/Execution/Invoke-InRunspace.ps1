function Invoke-InRunspace {
    <#
    .SYNOPSIS
        Runs a command in the module's isolated context (runspace or child process).
    .DESCRIPTION
        Returns a job id string when the command was started asynchronously, or a result
        object when it ran synchronously or could not be started.

        Connection commands stay synchronous in RUNSPACE mode only: the interactive auth
        prompt is raised inside the Nexus process, so the caller has to wait for it.
        Process contexts own their own console and are always asynchronous — polling
        there previously froze the listener for up to ten minutes.
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

    $rsEntry = Get-ModuleRunspace -ModuleEntry $ModuleEntry
    if (-not $rsEntry) {
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = "Failed to create context for: $($ModuleEntry.name)" })
        }
    }

    $verb = Get-CommandVerb -CommandName $CommandName
    $isConnectionCommand = $verb -in @('Connect', 'Disconnect', 'Login', 'Logout')
    $runAsync = $Async -and -not ($isConnectionCommand -and $rsEntry.Mode -eq 'runspace')

    if ($rsEntry.Mode -eq 'process') {
        if ($runAsync) { return Start-ProcessAsync -ProcessEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry }
        return Invoke-InProcess -ProcessEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry
    }

    if ($runAsync) { return Start-RunspaceAsync -RsEntry $rsEntry -CommandName $CommandName -Parameters $Parameters -ModuleEntry $ModuleEntry }
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
        command channel, so both are gated the same way. Stale pointers left by a
        finished job are cleared here.
    .PARAMETER ContextEntry
        The runspace or process context entry.
    .EXAMPLE
        $busy = Get-ActiveContextJob -ContextEntry $rsEntry
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ContextEntry)

    if (-not $ContextEntry.ActiveAsyncJobId) { return $null }

    $activeJobId = [string]$ContextEntry.ActiveAsyncJobId
    if ($script:BackgroundJobs -and $script:BackgroundJobs.ContainsKey($activeJobId) -and
        $script:BackgroundJobs[$activeJobId].Status -eq 'running') {
        return $activeJobId
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
    .EXAMPLE
        $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument($CommandName).AddArgument($Parameters)
    #>
    [CmdletBinding()]
    param()

    return @'
param($CommandName, $Params)

$cmd = Get-Command -Name $CommandName -ErrorAction Stop

$bound = @{}
foreach ($key in $Params.Keys) {
    $meta = $cmd.Parameters[$key]
    if (-not $meta) { throw "Parameter '$key' is not valid for command '$CommandName'." }

    $value = $Params[$key]
    $type  = $meta.ParameterType

    if ($type -eq [switch] -or $type -eq [bool]) {
        $bound[$key] = ($value -is [bool] -and $value) -or ("$value".Trim().ToLower() -in @('true', '1', 'yes', 'on'))
    } elseif ($type -eq [string[]] -and $value -is [string]) {
        $bound[$key] = @($value -split ',\s*')
    } else {
        $bound[$key] = $value
    }
}

& $cmd @bound *>&1
'@
}

function Invoke-RunspaceSync {
    param([object]$RsEntry, [string]$CommandName, [hashtable]$Parameters, [object]$ModuleEntry)

    $activeJobId = Get-ActiveContextJob -ContextEntry $RsEntry
    if ($activeJobId) { return New-ContextBusyResult -ModuleName $ModuleEntry.name -CommandName $CommandName -ActiveJobId $activeJobId }

    $startTime = Get-Date

    $ps = [PowerShell]::Create()
    $ps.Runspace = $RsEntry.Runspace
    $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument($CommandName).AddArgument($Parameters) | Out-Null

    Write-HubLog -Level Info -Message "Executing in runspace (sync): $CommandName" -Source $ModuleEntry.name
    $output = @()
    try {
        $results = $ps.Invoke()
        # Commands run with *>&1, so classify by record type — Streams.Error stays empty.
        $output += @(ConvertTo-HubOutput -Records $results)
        $output += @(ConvertTo-HubOutput -Records @($ps.Streams.Error))
        $output += @(ConvertTo-HubOutput -Records @($ps.Streams.Warning))
        $output += @(ConvertTo-HubOutput -Records @($ps.Streams.Information))
        $success = -not ($output | Where-Object { $_.stream -eq 'Error' })
        $verb = Get-CommandVerb -CommandName $CommandName
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

    $activeJobId = Get-ActiveContextJob -ContextEntry $RsEntry
    if ($activeJobId) { return New-ContextBusyResult -ModuleName $ModuleEntry.name -CommandName $CommandName -ActiveJobId $activeJobId }

    Remove-CompletedJob

    $jobId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $ps = [PowerShell]::Create()
    $ps.Runspace = $RsEntry.Runspace

    try {
        $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument($CommandName).AddArgument($Parameters) | Out-Null
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
        Id = $jobId; Module = $ModuleEntry.name; Command = $CommandName; Mode = 'runspace'
        PowerShell = $ps; AsyncResult = $asyncResult; StartedAt = Get-Date
        Status = 'running'; Result = $null; Context = $RsEntry
    }
    $RsEntry.ActiveAsyncJobId = $jobId
    $RsEntry.LastUsed = Get-Date
    Write-HubLog -Level Info -Message "Async job: $jobId ($($ModuleEntry.name)/$CommandName)"
    return $jobId
}
