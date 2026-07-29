function Read-HubSettings {
    <#
    .SYNOPSIS
        Loads settings.json (or settings.local.json when present).
    .DESCRIPTION
        Returns the parsed settings object. On a missing or corrupt file a default
        settings object is returned so the portal keeps serving instead of 500-ing.
    .EXAMPLE
        $settings = Read-HubSettings
    #>
    [CmdletBinding()]
    param()

    $default = [PSCustomObject]@{
        defaultPort          = 8090
        portRange            = @(8090, 8099)
        openBrowserOnStart   = $true
        logLevel             = 'Info'
        logRetentionDays     = 30
        scanOnStartup        = $false
        scanRoots            = @()
        scanDepth            = 2
        scanExclude          = @('node_modules', '.git', 'bin', 'obj', 'build', 'Tests')
        scanPublishedModules = $false
        publishedModulePaths = @()
        theme                = 'dark'
        favouriteCommands    = @()
        recentCommands       = @()
        maxRecentCommands    = 20
    }

    if (-not (Test-Path $script:SettingsFile)) {
        Write-HubLog -Level Warning -Message "Settings file not found: $($script:SettingsFile) — using defaults"
        return $default
    }

    try {
        return (Get-Content -Path $script:SettingsFile -Raw -Encoding utf8 | ConvertFrom-Json)
    } catch {
        Write-HubLog -Level Error -Message "Failed to read settings: $($_.Exception.Message) — using defaults"
        return $default
    }
}
