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
