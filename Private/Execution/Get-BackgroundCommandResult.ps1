function Update-BackgroundJobState {
    <#
    .SYNOPSIS
        Advances one job's state if it is still marked running; a no-op otherwise.
    .PARAMETER Job
        The tracked job entry.
    .EXAMPLE
        Update-BackgroundJobState -Job $job
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)

    if ($Job.Status -ne 'running') { return }
    if ($Job.Mode -eq 'process') { Complete-ProcessJob -Job $Job } else { Complete-RunspaceJob -Job $Job }
}

function Sync-BackgroundJob {
    <#
    .SYNOPSIS
        Advances every running background job one step.
    .DESCRIPTION
        Get-BackgroundCommandResult only ever advanced the one job a client was actively
        polling — a job nobody polls again (closed tab, dropped connection) left its
        module context locked (ActiveAsyncJobId set) until Nexus restarted, since nothing
        else called Complete-*Job for it. Called on every incoming request (see
        Invoke-RequestRouter) so a context recovers — and a hung job hits its timeout and
        gets cleared — as soon as any traffic reaches the listener, without needing a
        dedicated background thread (which would mean auditing every shared script-scoped
        variable in this module for concurrent-access safety, not a change to make in
        passing).
    .EXAMPLE
        Sync-BackgroundJob
    #>
    [CmdletBinding()]
    param()

    if (-not $script:BackgroundJobs) { return }
    foreach ($job in @($script:BackgroundJobs.Values | Where-Object { $_.Status -eq 'running' })) {
        Update-BackgroundJobState -Job $job
    }
    # Cancelled or timed-out runspace jobs whose pipeline has not confirmed it stopped.
    foreach ($job in @($script:BackgroundJobs.Values | Where-Object { $_.StopRequestedAt -and -not $_.StopReaped })) {
        Complete-PendingStop -Job $job
    }
}

function Get-BackgroundCommandResult {
    <#
    .SYNOPSIS
        Reports the state of a background job, collecting its result once it finishes.
    .PARAMETER JobId
        The job identifier returned when the command was started.
    .EXAMPLE
        Get-BackgroundCommandResult -JobId 'a1b2c3d4e5f6'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JobId)

    if (-not $script:BackgroundJobs -or -not $script:BackgroundJobs.ContainsKey($JobId)) {
        return [PSCustomObject]@{ id = $JobId; status = 'not_found'; result = $null }
    }

    $job = $script:BackgroundJobs[$JobId]
    Update-BackgroundJobState -Job $job

    if ($job.Status -eq 'running') {
        return [PSCustomObject]@{
            id = $JobId; status = 'running'; module = $job.Module; command = $job.Command
            elapsed = [math]::Round(((Get-Date) - $job.StartedAt).TotalSeconds, 1); result = $null
        }
    }

    return [PSCustomObject]@{
        id = $JobId; status = $job.Status; module = $job.Module; command = $job.Command
        result = $job.Result
    }
}

function Complete-RunspaceJob {
    <#
    .SYNOPSIS
        Collects the result of a finished runspace job, or fails it out once it has run
        past its timeout.
    .DESCRIPTION
        Without a timeout, a runspace job that never completes (a hung command, a module
        bug) held its context's ActiveAsyncJobId forever — Get-ActiveContextJob would
        report that module permanently busy until Nexus restarted. Process jobs already
        had this (TimeoutAt set in Start-ProcessAsync); this mirrors it for runspaces.
    .PARAMETER Job
        The tracked job entry.
    .EXAMPLE
        Complete-RunspaceJob -Job $job
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)

    if (-not $Job.AsyncResult.IsCompleted) {
        if ((Get-Date) -lt $Job.TimeoutAt) { return }

        Stop-RunspaceJobAsync -Job $Job
        $built = Get-RunspaceCommandOutput -Output $Job.Output -Summary $Job.Summary -ErrorMessage 'Command timed out'
        $Job.Result = [PSCustomObject]@{
            success = $false; output = @($built.output)
            truncated = $built.truncated; totalCount = $built.totalCount
            durationMs = [math]::Round(((Get-Date) - $Job.StartedAt).TotalMilliseconds, 0)
        }
        $Job.Status = 'failed'
        # The context stays busy until Complete-PendingStop reaps the stop.
        Write-HubLog -Level Error -Message "Background job $($Job.Id) timed out"
        return
    }

    $errorMessage = $null
    try {
        $results = $Job.PowerShell.EndInvoke($Job.AsyncResult)
        if (-not $Job.Output) {
            # A job tracked without a streaming collection: shape what EndInvoke returned.
            $summary = @{}
            $shaped = @(ConvertTo-HubOutput -Records $results -MaxRows (Get-MaxOutputRow) -Summary $summary)
            $Job.Output = $shaped
            $Job.Summary = $summary
        }
    } catch {
        # EndInvoke wraps the real failure; surface the inner message to the portal.
        $errorMessage = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
    }

    try {
        $built = Get-RunspaceCommandOutput -Output $Job.Output -Summary $Job.Summary -ErrorMessage $errorMessage
        $Job.Result = [PSCustomObject]@{
            success = $built.success; output = @($built.output)
            truncated = $built.truncated; totalCount = $built.totalCount
            durationMs = [math]::Round(((Get-Date) - $Job.StartedAt).TotalMilliseconds, 0)
        }
        $Job.Status = if ($built.success) { 'completed' } else { 'failed' }

        # Mirrors what Invoke-RunspaceSync does for a synchronous connect — connection
        # commands run through this same async path now, so it's the only place left
        # that updates it.
        $verb = Get-CommandVerb -CommandName $Job.Command
        if ($verb -eq 'Connect' -and $built.success) { $Job.Context.Connected = $true }
        if ($verb -eq 'Disconnect') { $Job.Context.Connected = $false }
    } finally {
        # Dispose the PowerShell instance but KEEP the runspace alive
        # (persistent runspaces maintain auth state between commands)
        $Job.PowerShell.Dispose()
        Clear-JobContext -Job $Job
    }

    Write-HubLog -Level Info -Message "Background job $($Job.Id) completed ($($Job.Status))"
}

function Stop-RunspaceJobAsync {
    <#
    .SYNOPSIS
        Asks a runspace job's pipeline to stop without waiting for it.
    .DESCRIPTION
        Uses BeginStop: a synchronous Stop() blocks until the pipeline obeys, and a
        command stuck in a call PowerShell cannot interrupt would freeze the listener.
        Complete-PendingStop (run from Sync-BackgroundJob and Get-ActiveContextJob)
        disposes the PowerShell instance once it has stopped, or tears the runspace down
        if it has not after five seconds. The context stays busy until then. If BeginStop
        throws, the context is recycled immediately.
    .PARAMETER Job
        The tracked job entry.
    .EXAMPLE
        Stop-RunspaceJobAsync -Job $job
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)

    $Job.StopRequestedAt = Get-Date
    $Job.StopReaped = $false
    $Job.StopAsync = $null
    try { $Job.StopAsync = $Job.PowerShell.BeginStop($null, $null) } catch {
        Write-HubLog -Level Warning -Message "Failed to stop job $($Job.Id): $($_.Exception.Message) - recycling its runspace"
        # Nothing will ever confirm the stop: drop the context now instead of holding it busy.
        if ($Job.Context) { Remove-ModuleContext -Context $Job.Context -JobId $Job.Id }
        Clear-JobContext -Job $Job
        $Job.StopReaped = $true
    }
}

function Complete-PendingStop {
    <#
    .SYNOPSIS
        Finishes off a job whose stop was requested: dispose it once stopped, or drop its
        runspace if it has not stopped after five seconds.
    .PARAMETER Job
        The tracked job entry.
    .PARAMETER GraceSeconds
        How long a pipeline gets to stop before its runspace is discarded.
    .EXAMPLE
        Complete-PendingStop -Job $job
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Job,
        [int]$GraceSeconds = 5
    )

    if ($Job.StopReaped) { return }

    $stopped = $Job.StopAsync -and $Job.StopAsync.IsCompleted
    if (-not $stopped) {
        $state = try { [string]$Job.PowerShell.InvocationStateInfo.State } catch { '' }
        $stopped = $state -in @('Stopped', 'Failed', 'Completed')
    }
    if ($stopped) {
        try { $Job.PowerShell.Dispose() } catch {
            Write-HubLog -Level Debug -Message "Failed to dispose stopped job $($Job.Id): $($_.Exception.Message)"
        }
        $Job.StopReaped = $true
        # The old pipeline is gone: the context's runspace is free again.
        Clear-JobContext -Job $Job
        return
    }

    if (((Get-Date) - $Job.StopRequestedAt).TotalSeconds -lt $GraceSeconds) { return }

    # The pipeline ignored the stop request. Discard the runspace so the module context
    # is recreated on the next call. The PowerShell instance is left to the closing
    # runspace: disposing it directly would wait on the stuck pipeline.
    Write-HubLog -Level Warning -Message "Job $($Job.Id) did not stop within $GraceSeconds s - discarding its runspace"
    if ($Job.Context) { Remove-ModuleContext -Context $Job.Context -JobId $Job.Id }
    Clear-JobContext -Job $Job
    $Job.StopReaped = $true
}

function Complete-ProcessJob {
    <#
    .SYNOPSIS
        Collects the result of a child-process job, if its response has arrived.
    .DESCRIPTION
        Returns without changing state while the command is still running, so the
        listener never waits on the process's command channel.
    .PARAMETER Job
        The tracked job entry.
    .EXAMPLE
        Complete-ProcessJob -Job $job
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)

    $context = $Job.Context
    $duration = [math]::Round(((Get-Date) - $Job.StartedAt).TotalMilliseconds, 0)

    $response = Receive-ProcessResponse -ProcessEntry $context -RequestId ([string]$Job.RequestId)
    if ($response) {
        $result = ConvertFrom-ProcessResponse -Response $response -ModuleName $Job.Module -CommandName $Job.Command -DurationMs $duration
        $Job.Result = [PSCustomObject]@{
            success = $result.success; output = @($result.output)
            truncated = $result.truncated; totalCount = $result.totalCount
            durationMs = $result.durationMs
        }
        $Job.Status = if ($result.success) { 'completed' } else { 'failed' }
        Update-ProcessConnectionState -ProcessEntry $context -CommandName $Job.Command -Success $result.success
        Clear-JobContext -Job $Job
        Write-HubLog -Level Info -Message "Background job $($Job.Id) completed ($($Job.Status))"
        return
    }

    $failure = $null
    if ($context.Process -and $context.Process.HasExited) { $failure = 'Process exited unexpectedly' }
    elseif ((Get-Date) -gt $Job.TimeoutAt) { $failure = 'No response from process (timeout)' }
    if (-not $failure) { return }

    $Job.Result = [PSCustomObject]@{
        success = $false
        output = @([PSCustomObject]@{ stream = 'Error'; message = $failure })
        durationMs = $duration
    }
    $Job.Status = 'failed'
    # A timed-out worker is still running the command and would write a late response;
    # discard the context (which also releases its busy flag) so the next call starts clean.
    if ($context -and $failure -like '*timeout*') { Remove-ModuleContext -Context $context }
    Clear-JobContext -Job $Job
    Write-HubLog -Level Error -Message "Background job $($Job.Id) failed: $failure"
}

function Clear-JobContext {
    <#
    .SYNOPSIS
        Releases the module context a finished job was holding.
    .PARAMETER Job
        The tracked job entry.
    .EXAMPLE
        Clear-JobContext -Job $job
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)

    $context = $Job.Context
    if ($context -and $context.ActiveAsyncJobId -eq $Job.Id) {
        $context.ActiveAsyncJobId = $null
        $context.LastUsed = Get-Date
    }
}

function Remove-CompletedJob {
    <#
    .SYNOPSIS
        Trims finished jobs so the tracker does not grow for the life of the server.
    .PARAMETER Keep
        How many finished jobs to retain for late polls.
    .EXAMPLE
        Remove-CompletedJob -Keep 50
    #>
    [CmdletBinding()]
    param([int]$Keep = 50)

    if (-not $script:BackgroundJobs) { return }

    $finished = @($script:BackgroundJobs.Values | Where-Object { $_.Status -ne 'running' -and -not ($_.StopRequestedAt -and -not $_.StopReaped) } | Sort-Object StartedAt -Descending)
    if ($finished.Count -le $Keep) { return }

    foreach ($job in $finished[$Keep..($finished.Count - 1)]) {
        $script:BackgroundJobs.Remove($job.Id)
    }
    Write-HubLog -Level Debug -Message "Pruned $($finished.Count - $Keep) finished job(s)"
}
