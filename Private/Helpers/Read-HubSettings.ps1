function Read-HubSettings {
    <#
    .SYNOPSIS
        Loads settings.json (or settings.local.json when present).
    .DESCRIPTION
        Returns the parsed settings object with any missing keys filled from the defaults.
        On a missing or corrupt file a default settings object is returned so the portal
        keeps serving instead of 500-ing; a corrupt file is first moved to
        settings.json.corrupt-<timestamp> so a later save cannot destroy it.
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

    $loaded = $null
    try {
        $loaded = Get-Content -Path $script:SettingsFile -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($loaded -isnot [System.Management.Automation.PSCustomObject]) { throw 'Settings file does not contain a JSON object.' }
    } catch {
        # Keep the unreadable file: the next save would otherwise overwrite the user's data.
        $backup = "$($script:SettingsFile).corrupt-$(Get-Date -Format 'yyyyMMddHHmmss')"
        # Move, not copy: later reads then hit the "not found" path instead of writing a new backup each time.
        try { Move-Item -Path $script:SettingsFile -Destination $backup -Force -ErrorAction Stop } catch { $backup = $null }
        $note = if ($backup) { "moved to $backup" } else { 'backup failed' }
        Write-HubLog -Level Warning -Message "Failed to read settings: $($_.Exception.Message) ($note) - using defaults"
        return $default
    }

    # Backfill: a partial file must not lack keys that callers index into.
    foreach ($property in $default.PSObject.Properties) {
        if (-not $loaded.PSObject.Properties[$property.Name]) {
            $loaded | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
    }
    return $loaded
}
