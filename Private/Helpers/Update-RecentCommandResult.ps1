function Update-RecentCommandResult {
    <#
    .SYNOPSIS
        Patches a recent-commands entry with the real outcome once its background job finishes.
    .DESCRIPTION
        Async commands are logged to recentCommands with success = $null when they start,
        since the outcome isn't known yet. This fills in the true result so the dashboard
        doesn't keep showing a still-running or since-succeeded command as failed.
    .PARAMETER JobId
        The background job whose result just became available.
    .PARAMETER Success
        Whether the job completed successfully.
    .EXAMPLE
        Update-RecentCommandResult -JobId 'a1b2c3d4e5f6' -Success $true
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][bool]$Success
    )

    try {
        $settings = Read-HubSettings
        $entry = @($settings.recentCommands) | Where-Object { $_.jobId -eq $JobId -and $null -eq $_.success } | Select-Object -First 1
        if (-not $entry) { return }

        $entry.success = $Success
        Save-HubSettings -Settings $settings
    } catch {
        Write-HubLog -Level Debug -Message "Failed to update recent command result for job $JobId : $($_.Exception.Message)"
    }
}
