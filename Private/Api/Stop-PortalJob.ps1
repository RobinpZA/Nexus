function Stop-PortalJob {
    <#
    .SYNOPSIS
        API handler: DELETE /api/jobs/{id}
        Cancels a running job. 200 { success, status: "cancelled" }; 404 for an unknown
        id; 409 when the job has already finished.
    #>
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$JobId
    )

    switch (Stop-BackgroundJob -JobId $JobId) {
        'cancelled' { Write-JsonResponse -Context $Context -Data @{ success = $true; status = 'cancelled' } }
        'finished'  { Write-ErrorResponse -Context $Context -StatusCode 409 -Message "Job already finished: $JobId" }
        default     { Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Job not found: $JobId" }
    }
}
