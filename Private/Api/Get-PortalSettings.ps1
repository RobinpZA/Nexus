function Get-PortalSettings {
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)
    try {
        $settings = Read-HubSettings
        $hubVersion = if ($script:NexusVersion) { [string]$script:NexusVersion } else { 'unknown' }
        $settings | Add-Member -NotePropertyName hubVersion -NotePropertyValue $hubVersion -Force
        Write-JsonResponse -Context $Context -Data $settings
    } catch { Write-ErrorResponse -Context $Context -StatusCode 500 -Message "Failed to read settings: $($_.Exception.Message)" }
}
