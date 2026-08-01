# ─────────────────────────────────────────────────────────────
# Nexus — Root Module Loader
# ─────────────────────────────────────────────────────────────

# Module-scoped variables
$script:NexusRoot       = $PSScriptRoot
$script:SeedConfigPath  = Join-Path $PSScriptRoot 'Config'

# User state (registry, settings, logs) lives outside the module folder. Installed
# from the Gallery, $PSScriptRoot is a versioned, often read-only path — writing there
# fails under AllUsers scope and loses everything on every module update. Override with
# $env:NEXUS_HOME (e.g. to keep working from a repo checkout during development).
$script:DataRoot = if ($env:NEXUS_HOME) { $env:NEXUS_HOME } else { Join-Path $env:LOCALAPPDATA 'Nexus' }
$script:ConfigPath = Join-Path $script:DataRoot 'Config'
$script:LogDir     = Join-Path $script:DataRoot 'Logs'

foreach ($dir in @($script:ConfigPath, $script:LogDir)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

# Seed user config from the shipped defaults on first run. Config/ under the module
# root is read-only template data from here on — Read-HubSettings/Write-ModuleRegistry
# never touch it again.
foreach ($seedFile in @('settings.json', 'modules.json')) {
    $dest = Join-Path $script:ConfigPath $seedFile
    if (-not (Test-Path $dest)) {
        $src = Join-Path $script:SeedConfigPath $seedFile
        if (Test-Path $src) { Copy-Item -Path $src -Destination $dest }
    }
}

$script:RegistryFile    = Join-Path $script:ConfigPath 'modules.json'
$script:SettingsFile    = Join-Path $script:ConfigPath 'settings.json'
$registryLocalFile      = Join-Path $script:ConfigPath 'modules.local.json'
$settingsLocalFile      = Join-Path $script:ConfigPath 'settings.local.json'
if (Test-Path $registryLocalFile) {
    $script:RegistryFile = $registryLocalFile
}
if (Test-Path $settingsLocalFile) {
    $script:SettingsFile = $settingsLocalFile
}
$script:PortalRoot      = Join-Path $PSScriptRoot 'Assets' 'portal'
$script:Listener        = $null
$script:StopListener    = $false
$manifestPath           = Join-Path $PSScriptRoot 'Nexus.psd1'
try {
    $script:NexusVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion.ToString()
} catch {
    $script:NexusVersion = '0.0.0'
}
$script:ImportedModules = @{}
$script:MetadataCache   = @{}   # manifest path -> parsed metadata, keyed on file stamp
$script:LogLevel        = 'Info'   # overridden from settings at startup
$script:HubLogSession   = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:BackgroundJobs  = @{}
$script:ModuleRunspaces  = @{}

# Dot-source all Private and Public functions
$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private" -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue)
$Public  = @(Get-ChildItem -Path "$PSScriptRoot\Public"  -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($Private + $Public)) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to import $($file.FullName): $_"
    }
}

# Export public functions
Export-ModuleMember -Function $Public.BaseName

# Convenience alias
Set-Alias -Name 'ops' -Value 'Start-Nexus'
Export-ModuleMember -Alias 'ops'


