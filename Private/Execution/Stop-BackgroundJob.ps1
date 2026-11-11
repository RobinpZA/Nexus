function Stop-BackgroundJob {
    <#
    .SYNOPSIS
        Cancels a running background job.
    .DESCRIPTION
        Returns 'cancelled', 'finished' (the job was no longer running) or 'not_found'.

        Runspace jobs are stopped with BeginStop, which does not wait; the job is marked
        cancelled at once and keeps the output captured so far. Complete-PendingStop
        (called from Sync-BackgroundJob) disposes the PowerShell instance when it has
        stopped, or discards the runspace if it has not after five seconds, so the module
        context is recreated on the next call.

        Process jobs are single-command workers: the worker is killed through
        Remove-ModuleContext and the next request starts a fresh one.

        Commands that run in the Nexus session (Invoke-RegisteredCommand) are synchronous
        and are never tracked as jobs, so there is nothing to cancel for them.

        A cancelled runspace job keeps its module context busy until Complete-PendingStop
        reaps the stop (pipeline stopped, or runspace discarded after the grace period):
        the old pipeline is still running on that runspace until then. If BeginStop itself
        fails, the context is recycled at once. A job whose pipeline has already completed
        is reported as 'finished'. Process jobs release the context via Remove-ModuleContext.
    .PARAMETER JobId
        The job identifier returned when the command was started.
    .EXAMPLE
        Stop-BackgroundJob -JobId 'a1b2c3d4e5f6'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$JobId)

    if (-not $script:BackgroundJobs -or -not $script:BackgroundJobs.ContainsKey($JobId)) { return 'not_found' }

    $job = $script:BackgroundJobs[$JobId]
    # The job may have finished since the last sync; that is a 'finished', not a cancel.
    if ($job.Status -eq 'running' -and $job.Mode -ne 'process' -and $job.AsyncResult -and $job.AsyncResult.IsCompleted) {
        Update-BackgroundJobState -Job $job
        return 'finished'
    }
    Update-BackgroundJobState -Job $job
    if ($job.Status -ne 'running') { return 'finished' }

    if (-not $PSCmdlet.ShouldProcess($JobId, 'Cancel background job')) { return 'finished' }

    $duration = [math]::Round(((Get-Date) - $job.StartedAt).TotalMilliseconds, 0)

    if ($job.Mode -eq 'process') {
        $job.Result = [PSCustomObject]@{
            success = $false; output = @(); truncated = $false; totalCount = 0; durationMs = $duration
        }
        $job.Status = 'cancelled'
        if ($job.Context) { Remove-ModuleContext -Context $job.Context }
        Clear-JobContext -Job $job
    } else {
        Stop-RunspaceJobAsync -Job $job
        $built = Get-RunspaceCommandOutput -Output $job.Output -Summary $job.Summary
        $job.Result = [PSCustomObject]@{
            success = $false; output = @($built.output)
            truncated = $built.truncated; totalCount = $built.totalCount; durationMs = $duration
        }
        $job.Status = 'cancelled'
    }

    Write-HubLog -Level Info -Message "Background job $JobId cancelled" -Source $job.Module
    return 'cancelled'
}
