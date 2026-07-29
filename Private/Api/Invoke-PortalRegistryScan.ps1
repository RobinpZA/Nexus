function Invoke-PortalRegistryScan {
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)
    $settings = Read-HubSettings
    $scanRoots = @($settings.scanRoots); $scanDepth = $settings.scanDepth; $scanExclude = @($settings.scanExclude)
    $scanPublished = [bool]$settings.scanPublishedModules; $publishedPaths = @($settings.publishedModulePaths)
    if ($scanRoots.Count -eq 0 -and -not $scanPublished) {
        Write-ErrorResponse -Context $Context -StatusCode 400 -Message "No scan roots configured and published scanning is disabled"; return
    }
    try {
        # A scan may add, move or remove modules — start from a clean cache.
        Clear-MetadataCache
        $scanParams = @{ ScanRoots = $scanRoots; MaxDepth = $scanDepth; Exclude = $scanExclude }
        if ($scanPublished) { $scanParams['IncludePublished'] = $true; if ($publishedPaths.Count -gt 0) { $scanParams['PublishedModulePaths'] = $publishedPaths } }
        $discovered = Invoke-ModuleScan @scanParams
        $syncResult = Sync-ModuleRegistry -Discovered $discovered
        Write-JsonResponse -Context $Context -Data @{ success = $true; added = $syncResult.Added; updated = $syncResult.Updated; missing = $syncResult.Missing; total = $syncResult.Total }
    } catch {
        Write-HubLog -Level Error -Message "Scan error: $($_.Exception.Message)"
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message $_.Exception.Message
    }
}
