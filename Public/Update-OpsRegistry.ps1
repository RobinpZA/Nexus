function Update-OpsRegistry {
    <#
    .SYNOPSIS
        Scans module folders and synchronises the Nexus registry with what it finds.
    .DESCRIPTION
        Walks the configured scan roots (or the roots passed in -ScanRoots) looking for module
        manifests, then adds new modules, refreshes known ones and marks registered modules
        whose path has disappeared as missing. Settings (scanRoots, scanDepth, scanExclude,
        scanPublishedModules) are read through Read-HubSettings. The scan itself only reads
        the file system; the registry write is guarded by ShouldProcess, so -WhatIf scans and
        reports but leaves the registry untouched.
    .PARAMETER ScanRoots
        Folders to scan instead of the scanRoots setting.
    .PARAMETER IncludePublished
        Also scan installed (PSModulePath) modules, even when scanPublishedModules is off.
    .EXAMPLE
        Update-OpsRegistry
        Scans the configured scan roots and updates the registry.
    .EXAMPLE
        Update-OpsRegistry -ScanRoots 'C:\Modules' -IncludePublished
        Scans one folder plus installed modules.
    .EXAMPLE
        Update-OpsRegistry -WhatIf
        Shows what would be synchronised without writing the registry.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$ScanRoots,
        [switch]$IncludePublished
    )

    $settings = Read-HubSettings
    if (-not $ScanRoots) { $ScanRoots = @($settings.scanRoots) }
    if ($ScanRoots.Count -eq 0) {
        Write-Warning 'No scan roots configured.'
        return
    }

    Write-HubLog -Level Info -Message "Scanning $($ScanRoots.Count) root(s)..."
    $scanParams = @{
        ScanRoots = $ScanRoots
        MaxDepth  = $settings.scanDepth
        Exclude   = @($settings.scanExclude)
    }
    if ($IncludePublished -or $settings.scanPublishedModules) { $scanParams['IncludePublished'] = $true }
    # Child scope: under -WhatIf the scan's log writes would otherwise be reported as skipped.
    $discovered = @(& { $WhatIfPreference = $false; Invoke-ModuleScan @scanParams })

    # Invoke-ModuleScan and Sync-ModuleRegistry have no -WhatIf of their own; the scan is
    # read-only, so only the sync (which writes modules.json) is guarded here.
    if (-not $PSCmdlet.ShouldProcess("Nexus registry ($($discovered.Count) module(s) discovered)", 'Synchronise')) { return }

    $result = Sync-ModuleRegistry -Discovered $discovered

    Write-Host ''
    Write-Host '  Registry Update Summary' -ForegroundColor Cyan
    Write-Host "    Added:   $($result.Added)" -ForegroundColor Green
    Write-Host "    Updated: $($result.Updated)" -ForegroundColor Yellow
    Write-Host "    Missing: $($result.Missing)" -ForegroundColor $(if ($result.Missing -gt 0) { 'Red' } else { 'DarkGray' })
    Write-Host "    Total:   $($result.Total)" -ForegroundColor White
    Write-Host ''
}
