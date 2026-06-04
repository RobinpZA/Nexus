function Update-OpsRegistry {
    [CmdletBinding()]
    param([string[]]$ScanRoots, [switch]$IncludePublished)
    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
    if (-not $ScanRoots) { $ScanRoots = @($settings.scanRoots) }
    if ($ScanRoots.Count -eq 0) { Write-Warning "No scan roots configured."; return }
    Write-HubLog -Level Info -Message "Scanning $($ScanRoots.Count) root(s)..."
    $scanParams = @{ ScanRoots = $ScanRoots; MaxDepth = $settings.scanDepth; Exclude = @($settings.scanExclude) }
    if ($IncludePublished -or $settings.scanPublishedModules) { $scanParams['IncludePublished'] = $true }
    $discovered = Invoke-ModuleScan @scanParams
    $result = Sync-ModuleRegistry -Discovered $discovered
    Write-Host ''; Write-Host '  Registry Update Summary' -ForegroundColor Cyan
    Write-Host "    Added:   $($result.Added)" -ForegroundColor Green
    Write-Host "    Updated: $($result.Updated)" -ForegroundColor Yellow
    Write-Host "    Missing: $($result.Missing)" -ForegroundColor $(if ($result.Missing -gt 0) { 'Red' } else { 'DarkGray' })
    Write-Host "    Total:   $($result.Total)" -ForegroundColor White; Write-Host ''
}
