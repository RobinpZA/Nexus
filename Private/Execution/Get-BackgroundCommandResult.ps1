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

        try { $Job.PowerShell.Stop() } catch {
            Write-HubLog -Level Debug -Message "Failed to stop timed-out job $($Job.Id): $($_.Exception.Message)"
        }
        $Job.Result = [PSCustomObject]@{
            success = $false
            output = @([PSCustomObject]@{ stream = 'Error'; message = 'Command timed out' })
            durationMs = [math]::Round(((Get-Date) - $Job.StartedAt).TotalMilliseconds, 0)
        }
        $Job.Status = 'failed'
        $Job.PowerShell.Dispose()
        Clear-JobContext -Job $Job
        Write-HubLog -Level Error -Message "Background job $($Job.Id) timed out"
        return
    }

    try {
        $results = $Job.PowerShell.EndInvoke($Job.AsyncResult)

        # Commands run with *>&1, so classify by record type — Streams.Error stays empty.
        $output = @()
        $output += @(ConvertTo-HubOutput -Records $results)
        $output += @(ConvertTo-HubOutput -Records @($Job.PowerShell.Streams.Error))
        $output += @(ConvertTo-HubOutput -Records @($Job.PowerShell.Streams.Warning))
        $output += @(ConvertTo-HubOutput -Records @($Job.PowerShell.Streams.Information))

        $success = -not ($output | Where-Object { $_.stream -eq 'Error' })
        $Job.Result = [PSCustomObject]@{
            success = $success; output = $output
            durationMs = [math]::Round(((Get-Date) - $Job.StartedAt).TotalMilliseconds, 0)
        }
        $Job.Status = if ($success) { 'completed' } else { 'failed' }

        # Mirrors what Invoke-RunspaceSync does for a synchronous connect — connection
        # commands run through this same async path now, so it's the only place left
        # that updates it.
        $verb = Get-CommandVerb -CommandName $Job.Command
        if ($verb -eq 'Connect' -and $success) { $Job.Context.Connected = $true }
        if ($verb -eq 'Disconnect') { $Job.Context.Connected = $false }
    } catch {
        # EndInvoke wraps the real failure; surface the inner message to the portal.
        $message = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        $Job.Result = [PSCustomObject]@{
            success = $false
            output = @([PSCustomObject]@{ stream = 'Error'; message = $message })
            durationMs = [math]::Round(((Get-Date) - $Job.StartedAt).TotalMilliseconds, 0)
        }
        $Job.Status = 'failed'
    } finally {
        # Dispose the PowerShell instance but KEEP the runspace alive
        # (persistent runspaces maintain auth state between commands)
        $Job.PowerShell.Dispose()
        Clear-JobContext -Job $Job
    }

    Write-HubLog -Level Info -Message "Background job $($Job.Id) completed ($($Job.Status))"
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

    $response = Receive-ProcessResponse -ProcessEntry $context
    if ($response) {
        $result = ConvertFrom-ProcessResponse -Response $response -ModuleName $Job.Module -CommandName $Job.Command -DurationMs $duration
        $Job.Result = [PSCustomObject]@{ success = $result.success; output = @($result.output); durationMs = $result.durationMs }
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

    $finished = @($script:BackgroundJobs.Values | Where-Object { $_.Status -ne 'running' } | Sort-Object StartedAt -Descending)
    if ($finished.Count -le $Keep) { return }

    foreach ($job in $finished[$Keep..($finished.Count - 1)]) {
        $script:BackgroundJobs.Remove($job.Id)
    }
    Write-HubLog -Level Debug -Message "Pruned $($finished.Count - $Keep) finished job(s)"
}
