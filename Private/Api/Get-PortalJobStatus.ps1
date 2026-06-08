function Get-PortalJobStatus {
    <#
    .SYNOPSIS
        API handler: GET /api/jobs/{id}
    #>
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$JobId
    )

    if (-not $script:BackgroundJobs -or -not $script:BackgroundJobs.ContainsKey($JobId)) {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Job not found: $JobId"
        return
    }

    $jobInfo = Get-BackgroundCommandResult -JobId $JobId

    $data = @{
        jobId   = $jobInfo.id
        status  = $jobInfo.status
        module  = $jobInfo.module
        command = $jobInfo.command
    }

    if ($jobInfo.status -eq 'running') {
        $data['elapsed'] = $jobInfo.elapsed
    }

    if ($jobInfo.result) {
        $data['success']    = $jobInfo.result.success
        $data['durationMs'] = $jobInfo.result.durationMs
        $data['output']     = @($jobInfo.result.output)
    }

    Write-JsonResponse -Context $Context -Data $data
}
