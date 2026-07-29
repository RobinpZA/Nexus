BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Nexus.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestRegistry.ps1')
    $script:TestRegistry = Enter-TestRegistry -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
}

AfterAll {
    Exit-TestRegistry -Context $script:TestRegistry
}

Describe 'Module Registry' {

    It 'Read-ModuleRegistry returns the expected structure' {
        $registry = & (Get-Module Nexus) { Read-ModuleRegistry }
        $registry | Should -Not -BeNullOrEmpty
        $registry.version | Should -Be '1.0'
        @($registry.modules).Count | Should -Be 2
        $registry.modules.name | Should -Contain 'FixtureModule'
    }

    It 'Returns a usable default when the registry file is missing' {
        $registry = & (Get-Module Nexus) {
            $real = $script:RegistryFile
            $script:RegistryFile = Join-Path ([System.IO.Path]::GetTempPath()) 'nexus-missing-registry.json'
            try { Read-ModuleRegistry } finally { $script:RegistryFile = $real }
        }
        $registry | Should -Not -BeNullOrEmpty
        @($registry.modules).Count | Should -Be 0
    }

    It 'Test-ModulePath reports a missing path' {
        $result = & (Get-Module Nexus) { Test-ModulePath -Path 'C:\nonexistent\path.psd1' }
        $result.Exists | Should -BeFalse
        $result.Valid | Should -BeFalse
        $result.Error | Should -Match 'does not exist'
    }

    It 'Test-ModulePath validates a real manifest' {
        $manifest = Join-Path $PSScriptRoot 'Fixtures\FixtureModule\FixtureModule.psd1'
        $result = & (Get-Module Nexus) { param($p) Test-ModulePath -Path $p } $manifest
        $result.Exists | Should -BeTrue
        $result.Valid | Should -BeTrue
    }
}

Describe 'Module Metadata' {

    It 'Reads exported commands and version from a manifest' {
        $manifest = Join-Path $PSScriptRoot 'Fixtures\FixtureModule\FixtureModule.psd1'
        $meta = & (Get-Module Nexus) { param($p) Get-ModuleMetadata -Path $p } $manifest

        $meta.Name | Should -Be 'FixtureModule'
        $meta.Version | Should -Be '1.0.0'
        $meta.Commands | Should -Contain 'Get-FixtureValue'
        @($meta.Commands).Count | Should -Be 3
    }

    It 'Caches a parsed manifest and discards a stale entry' {
        $manifest = Join-Path $PSScriptRoot 'Fixtures\FixtureModule\FixtureModule.psd1'
        $probe = & (Get-Module Nexus) {
            param($p)
            $script:MetadataCache = @{}
            $null = Get-ModuleMetadata -Path $p
            $cachedAfterFirstRead = $script:MetadataCache.Count

            # An entry whose stamp no longer matches the file must not be served.
            $key = "$p|"
            $script:MetadataCache[$key].Stamp = 'stale'
            $reread = Get-ModuleMetadata -Path $p

            [PSCustomObject]@{
                Cached  = $cachedAfterFirstRead
                Version = $reread.Version
                Stamp   = $script:MetadataCache[$key].Stamp
            }
        } $manifest

        $probe.Cached | Should -Be 1
        $probe.Version | Should -Be '1.0.0'
        $probe.Stamp | Should -Not -Be 'stale'
    }
}
