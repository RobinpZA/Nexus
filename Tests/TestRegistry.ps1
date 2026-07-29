# Dot-sourced by test files that need a registry.
#
# Tests used to read the caller's real modules.local.json, which made assertions depend
# on whatever was registered on that machine — and meant the execution tests actually
# invoked a live command against a tenant. These helpers point the module at a temporary
# registry containing only the fixture module.

function Enter-TestRegistry {
    <#
    .SYNOPSIS
        Redirects Nexus at a temporary registry and settings file holding only fixtures.
    .PARAMETER FixtureRoot
        Path to the Tests/Fixtures folder.
    .EXAMPLE
        $ctx = Enter-TestRegistry -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FixtureRoot)

    $module = Get-Module Nexus
    if (-not $module) { throw 'Import the Nexus module before calling Enter-TestRegistry.' }

    $original = & $module { @{ Registry = $script:RegistryFile; Settings = $script:SettingsFile } }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "NexusTests_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    $registryPath = Join-Path $temp 'modules.json'
    $settingsPath = Join-Path $temp 'settings.json'

    @{
        version     = '1.0'
        lastScanUtc = $null
        scanRoots   = @()
        modules     = @(
            @{
                name = 'FixtureModule'; path = (Join-Path $FixtureRoot 'FixtureModule\FixtureModule.psd1')
                description = 'Test fixture'; version = '1.0.0'; category = 'Test'; tags = @('fixture')
                author = 'Robin Pieterse'; entryCommand = 'Get-FixtureValue'; requiresAdmin = $false
                autoImport = $false; enabled = $true; icon = 'box'; dependencies = @(); source = 'custom'
                projectUri = $null; lastValidated = $null; status = 'healthy'
            }
            @{
                name = 'DisabledModule'; path = (Join-Path $FixtureRoot 'FixtureModule\FixtureModule.psd1')
                description = 'Disabled fixture'; version = '1.0.0'; category = 'Test'; tags = @()
                author = 'Robin Pieterse'; entryCommand = $null; requiresAdmin = $false
                autoImport = $false; enabled = $false; icon = 'box'; dependencies = @(); source = 'custom'
                projectUri = $null; lastValidated = $null; status = 'healthy'
            }
        )
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $registryPath -Encoding utf8

    @{
        defaultPort = 8090; portRange = @(8090, 8099); openBrowserOnStart = $false
        logLevel = 'Error'; logRetentionDays = 30; scanOnStartup = $false; scanRoots = @()
        scanDepth = 2; scanExclude = @('node_modules'); scanPublishedModules = $false
        publishedModulePaths = @(); theme = 'dark'; favouriteCommands = @(); recentCommands = @()
        maxRecentCommands = 20
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding utf8

    & $module {
        param($r, $s)
        $script:RegistryFile = $r
        $script:SettingsFile = $s
        $script:MetadataCache = @{}
        $script:ImportedModules = @{}
    } $registryPath $settingsPath

    return @{ Original = $original; Temp = $temp; RegistryPath = $registryPath; SettingsPath = $settingsPath }
}

function Exit-TestRegistry {
    <#
    .SYNOPSIS
        Restores the real registry and settings paths and deletes the temporary ones.
    .PARAMETER Context
        The object returned by Enter-TestRegistry.
    .EXAMPLE
        Exit-TestRegistry -Context $ctx
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $module = Get-Module Nexus
    if ($module) {
        & $module {
            param($r, $s)
            $script:RegistryFile = $r
            $script:SettingsFile = $s
            $script:MetadataCache = @{}
        } $Context.Original.Registry $Context.Original.Settings
    }

    if (Test-Path $Context.Temp) { Remove-Item $Context.Temp -Recurse -Force -ErrorAction SilentlyContinue }
}
