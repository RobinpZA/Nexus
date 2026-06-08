# ─────────────────────────────────────────────────────────────
# Nexus — Root Module Loader
# ─────────────────────────────────────────────────────────────

# Module-scoped variables
$script:NexusRoot       = $PSScriptRoot
$script:ConfigPath      = Join-Path $PSScriptRoot 'Config'
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
$script:LogDir          = Join-Path $PSScriptRoot 'Logs'
$script:Listener        = $null
$script:StopListener    = $false
$manifestPath           = Join-Path $PSScriptRoot 'Nexus.psd1'
try {
    $script:NexusVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion.ToString()
} catch {
    $script:NexusVersion = '0.0.0'
}
$script:ImportedModules = @{}
$script:HubLogSession   = @()
$script:BackgroundJobs  = @{}
$script:ModuleRunspaces  = @{}

# Ensure Logs directory exists
if (-not (Test-Path $script:LogDir)) {
    New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
}

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


