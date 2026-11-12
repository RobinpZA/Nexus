BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Nexus.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestRegistry.ps1')
    $script:TestRegistry = Enter-TestRegistry -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
    $script:Nexus = Get-Module Nexus
}

AfterAll {
    Exit-TestRegistry -Context $script:TestRegistry
}

Describe 'Get-OpsModule output' {
    It 'emits Nexus.Module objects' {
        $result = @(Get-OpsModule)
        $result.Count | Should -BeGreaterThan 0
        $result[0].PSObject.TypeNames | Should -Contain 'Nexus.Module'
        $result.Name | Should -Contain 'FixtureModule'
    }

    It 'can be piped to Where-Object' {
        $result = @(Get-OpsModule | Where-Object Name -eq 'FixtureModule')
        $result.Count | Should -Be 1
        $result[0].Category | Should -Be 'Test'
    }
}

Describe 'Get-OpsCommand output' {
    It 'emits Nexus.Command objects' {
        $result = @(Get-OpsCommand -Module FixtureModule)
        $result.Count | Should -BeGreaterThan 0
        $result[0].PSObject.TypeNames | Should -Contain 'Nexus.Command'
        $result[0].Module | Should -Be 'FixtureModule'
    }

    It 'can be piped to Where-Object' {
        $all = @(Get-OpsCommand)
        $filtered = @(Get-OpsCommand | Where-Object Command -eq $all[0].Command)
        $filtered.Count | Should -BeGreaterThan 0
    }
}

Describe 'Update-OpsRegistry -WhatIf' {
    It 'does not change the registry' {
        $scanRoot = Join-Path $script:TestRegistry.Temp 'scanroot'
        $modDir = Join-Path $scanRoot 'WhatIfMod'
        New-Item -ItemType Directory -Path $modDir -Force | Out-Null
        'function Get-WhatIfThing { 1 }' | Set-Content -Path (Join-Path $modDir 'WhatIfMod.psm1') -Encoding utf8
        New-ModuleManifest -Path (Join-Path $modDir 'WhatIfMod.psd1') -RootModule 'WhatIfMod.psm1' -FunctionsToExport 'Get-WhatIfThing' -ModuleVersion '1.0.0'

        $before = Get-Content -Path $script:TestRegistry.RegistryPath -Raw
        $null = Update-OpsRegistry -ScanRoots $scanRoot -WhatIf 6>$null
        $after = Get-Content -Path $script:TestRegistry.RegistryPath -Raw
        $after | Should -Be $before
        (& $script:Nexus { Read-ModuleRegistry }).modules.name | Should -Not -Contain 'WhatIfMod'
    }
}

Describe 'Public function contract' {
    BeforeDiscovery {
        $manifest = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..' 'Nexus.psd1')
        $script:ExportCases = @($manifest.FunctionsToExport | ForEach-Object { @{ Name = $_ } })
    }

    It '<Name> has CmdletBinding, a synopsis and a description' -ForEach $script:ExportCases {
        $cmd = Get-Command -Name $Name -Module Nexus
        $cmd.CmdletBinding | Should -BeTrue
        $help = Get-Help -Name $Name
        [string]$help.Synopsis | Should -Not -BeNullOrEmpty
        ($help.description | Out-String).Trim() | Should -Not -BeNullOrEmpty
    }
}

Describe 'Start-Nexus port selection' {
    It 'tries defaultPort first, then the range' {
        $settings = [PSCustomObject]@{ defaultPort = 9123; portRange = @(8090, 8099) }
        $attempts = @(& $script:Nexus { param($s) Get-ListenerPortParameter -Settings $s } $settings)
        $attempts.Count | Should -Be 2
        $attempts[0].Port | Should -Be 9123
        $attempts[1].PortRangeStart | Should -Be 8090
        $attempts[1].PortRangeEnd | Should -Be 8099
    }

    It 'uses only the range when defaultPort is 0 or unset' {
        $settings = [PSCustomObject]@{ defaultPort = 0; portRange = @(8090, 8099) }
        $attempts = @(& $script:Nexus { param($s) Get-ListenerPortParameter -Settings $s } $settings)
        $attempts.Count | Should -Be 1
        $attempts[0].ContainsKey('Port') | Should -BeFalse
        $attempts[0].PortRangeStart | Should -Be 8090
    }

    It 'uses only an explicit -Port when given' {
        $settings = [PSCustomObject]@{ defaultPort = 9123; portRange = @(8090, 8099) }
        $attempts = @(& $script:Nexus { param($s) Get-ListenerPortParameter -Port 9555 -Settings $s } $settings)
        $attempts.Count | Should -Be 1
        $attempts[0].Port | Should -Be 9555
    }

    It 'Start-Nexus passes defaultPort to Start-HttpListener first and falls back to the range' {
        $calls = & $script:Nexus {
            $script:calls = [System.Collections.Generic.List[hashtable]]::new()
            function Start-HttpListener {
                [CmdletBinding()]
                param([int]$Port, [int]$PortRangeStart, [int]$PortRangeEnd)
                $null = $PortRangeEnd
                $script:calls.Add(@{ Port = $Port; Start = $PortRangeStart })
                if ($Port) { throw 'port busy' }
                throw 'stop here'
            }
            function Read-HubSettings { [PSCustomObject]@{ defaultPort = 9123; portRange = @(8090, 8099); logLevel = 'Error'; logRetentionDays = 30; scanOnStartup = $false; openBrowserOnStart = $false } }
            function Remove-OldLog { param($RetentionDays) $null = $RetentionDays }
            function Read-ModuleRegistry { [PSCustomObject]@{ modules = @() } }
            try { Start-Nexus -NoBrowser 6>$null } catch { $null = $_ }
            $script:calls
        }
        $calls.Count | Should -Be 2
        $calls[0].Port | Should -Be 9123
        $calls[1].Port | Should -Be 0
        $calls[1].Start | Should -Be 8090
    }
}
