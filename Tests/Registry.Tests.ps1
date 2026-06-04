BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Nexus.psd1'
    Import-Module $modulePath -Force
}

Describe 'Module Registry' {
    It 'Read-ModuleRegistry returns valid structure' {
        # This calls the private function via the module scope
        $registry = & (Get-Module Nexus) { Read-ModuleRegistry }
        $registry | Should -Not -BeNullOrEmpty
        $registry.modules | Should -Not -BeNullOrEmpty
    }

    It 'Registry contains expected seed modules' {
        $registry = & (Get-Module Nexus) { Read-ModuleRegistry }
        $names = $registry.modules | ForEach-Object { $_.name }
        $names | Should -Contain 'CA-BaselineAuditor'
        $names | Should -Contain 'M365UserOffboarding'
    }

    It 'Test-ModulePath returns correct structure' {
        $result = & (Get-Module Nexus) { Test-ModulePath -Path 'C:\nonexistent\path.psd1' }
        $result.Exists | Should -Be $false
        $result.Valid | Should -Be $false
    }
}
