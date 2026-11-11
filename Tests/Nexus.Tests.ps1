BeforeAll {
    $script:modulePath = Join-Path $PSScriptRoot '..' 'Nexus.psd1'
}

Describe 'Nexus Module' {
    It 'Module manifest is valid' {
        { Test-ModuleManifest -Path $script:modulePath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'Module imports without errors' {
        { Import-Module $script:modulePath -Force -ErrorAction Stop } | Should -Not -Throw
    }

    It 'Exports expected functions' {
        Import-Module $script:modulePath -Force
        $commands = Get-Command -Module Nexus
        $expected = @(
            'Start-Nexus', 'Stop-Nexus', 'Open-Nexus', 'Get-OpsModule', 'Import-OpsModule',
            'Get-OpsCommand', 'Invoke-OpsCommand', 'Register-OpsModule',
            'Unregister-OpsModule', 'Update-OpsRegistry'
        )
        foreach ($cmd in $expected) {
            $commands.Name | Should -Contain $cmd
        }
    }

    It 'Exports ops alias' {
        Import-Module $script:modulePath -Force
        $alias = Get-Alias -Name 'ops' -ErrorAction SilentlyContinue
        $alias | Should -Not -BeNullOrEmpty
        $alias.Definition | Should -Be 'Start-Nexus'
    }
}

Describe 'Nexus Module: manifest and exports agree' {
    BeforeAll {
        Import-Module $script:modulePath -Force
        $script:Manifest = Import-PowerShellDataFile -Path $script:modulePath
        $script:PublicFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'Public') -Filter '*.ps1' -File | ForEach-Object BaseName)
        $script:ExportedFunctions = @((Get-Module Nexus).ExportedFunctions.Keys)
        $script:ExportedAliases = @((Get-Module Nexus).ExportedAliases.Keys)
    }

    It 'FunctionsToExport lists no wildcard' {
        $script:Manifest.FunctionsToExport | Should -Not -Contain '*'
    }

    It 'FunctionsToExport matches the functions the loaded module exports' {
        $declared = @($script:Manifest.FunctionsToExport)
        $missing = $declared | Where-Object { $_ -notin $script:ExportedFunctions }
        $extra = $script:ExportedFunctions | Where-Object { $_ -notin $declared }
        @($missing) | Should -BeNullOrEmpty -Because "declared but not exported: $($missing -join ', ')"
        @($extra) | Should -BeNullOrEmpty -Because "exported but not declared: $($extra -join ', ')"
    }

    It 'FunctionsToExport matches the files in Public/' {
        $declared = @($script:Manifest.FunctionsToExport)
        $missing = $declared | Where-Object { $_ -notin $script:PublicFiles }
        $extra = $script:PublicFiles | Where-Object { $_ -notin $declared }
        @($missing) | Should -BeNullOrEmpty -Because "declared without a Public/ file: $($missing -join ', ')"
        @($extra) | Should -BeNullOrEmpty -Because "Public/ file not declared: $($extra -join ', ')"
    }

    It 'Exports Enable-NexusAutoStart' {
        $script:ExportedFunctions | Should -Contain 'Enable-NexusAutoStart'
        $script:Manifest.FunctionsToExport | Should -Contain 'Enable-NexusAutoStart'
    }

    It 'AliasesToExport matches the aliases the loaded module exports' {
        $declared = @($script:Manifest.AliasesToExport)
        $missing = $declared | Where-Object { $_ -notin $script:ExportedAliases }
        $extra = $script:ExportedAliases | Where-Object { $_ -notin $declared }
        @($missing) | Should -BeNullOrEmpty -Because "declared but not exported: $($missing -join ', ')"
        @($extra) | Should -BeNullOrEmpty -Because "exported but not declared: $($extra -join ', ')"
    }
}
