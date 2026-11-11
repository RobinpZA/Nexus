BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Nexus.psd1'
    Import-Module $modulePath -Force
    . (Join-Path $PSScriptRoot 'TestRegistry.ps1')
    $script:FixturePsd1 = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'FixtureModule' 'FixtureModule.psd1')).Path
    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "NexusP2_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    $script:OriginalLogDir = & (Get-Module Nexus) { $script:LogDir }
    & (Get-Module Nexus) { param($d) $script:LogDir = $d } $script:TempRoot
}

AfterAll {
    & (Get-Module Nexus) { Stop-ModuleContext; $script:ModuleRunspaces = @{} }
    & (Get-Module Nexus) { param($d) $script:LogDir = $d } $script:OriginalLogDir
    Remove-Item $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Phase 2: Process context hardening' {

    BeforeAll {
        $script:Entry = [PSCustomObject]@{ name = 'FixtureModule'; enabled = $true; isolation = 'process'; path = $script:FixturePsd1 }
    }

    AfterAll {
        & (Get-Module Nexus) { Stop-ModuleContext }
    }

    It 'Writes no .ps1 files to the comms dir and still serves metadata and connection requests' {
        $r = & (Get-Module Nexus) {
            param($e)
            $ctx = Get-ModuleRunspace -ModuleEntry $e
            $params = Get-ContextCommandParameters -ModuleEntry $e -CommandName 'Get-FixtureValue'
            $syn = Get-ContextCommandSynopsis -ModuleEntry $e -CommandNames @('Get-FixtureValue')
            $conn = Get-ContextConnectionState -ModuleEntry $e
            [PSCustomObject]@{
                Mode   = $ctx.Mode
                Files  = @(Get-ChildItem -LiteralPath $ctx.CommsDir -Filter '*.ps1' -ErrorAction SilentlyContinue)
                Params = $params
                Syn    = $syn
                Conn   = $conn
            }
        } $script:Entry
        $r.Mode | Should -Be 'process'
        $r.Files.Count | Should -Be 0
        $r.Params.status | Should -Be 'ok'
        $r.Params.data.command | Should -Be 'Get-FixtureValue'
        $r.Syn.status | Should -Be 'ok'
        $r.Conn.status | Should -Be 'ok'
        $r.Conn.data.active | Should -BeTrue
    }

    It 'Restricts the comms dir to the current user and SYSTEM with no inherited rules' -Skip:(-not $IsWindows) {
        $dir = & (Get-Module Nexus) { param($e) (Get-ModuleRunspace -ModuleEntry $e).CommsDir } $script:Entry
        $acl = Get-Acl -LiteralPath $dir
        $acl.AreAccessRulesProtected | Should -BeTrue
        $rules = @($acl.Access)
        @($rules | Where-Object IsInherited).Count | Should -Be 0
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sys = 'S-1-5-18'
        $sids = @($rules | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
        $sids | Should -Contain $me
        $sids | Should -Contain $sys
        @($sids | Where-Object { $_ -notin @($me, $sys) }).Count | Should -Be 0
    }

    It 'Rejects a module name that could break a quoted argument' {
        foreach ($bad in @('a"b', 'trail\', "line`nbreak", ' ')) {
            $msg = & (Get-Module Nexus) {
                param($n)
                try { $null = New-ProcessContext -ModuleEntry ([PSCustomObject]@{ name = $n; path = 'C:\x\Mod.psd1' }); '' } catch { $_.Exception.Message }
            } $bad
            $msg | Should -Match 'Invalid module name' -Because "'$bad' must be rejected"
        }
    }

    It 'Rejects a scope name containing a double quote' {
        $msg = & (Get-Module Nexus) {
            try { $null = New-ProcessContext -ModuleEntry ([PSCustomObject]@{ name = 'Good'; path = 'C:\x\Bad"Scope.psd1' }); '' } catch { $_.Exception.Message }
        }
        $msg | Should -Match 'Invalid module (scope )?name'
    }

    It 'Accepts names with spaces and apostrophes (they are quoted on the command line)' {
        foreach ($ok in @('Friendly Name', "Robin's Tools")) {
            $msg = & (Get-Module Nexus) {
                param($n)
                try { $null = New-ProcessContext -ModuleEntry ([PSCustomObject]@{ name = $n; path = 'C:\x\My Module.psd1' }); '' } catch { $_.Exception.Message }
            } $ok
            $msg | Should -Not -Match 'Invalid module' -Because "'$ok' is a valid name"
        }
    }
}

Describe 'Phase 2: Worker lifecycle' {

    It 'Exits after its parent process dies' {
        $pwsh = (Get-Process -Id $PID).Path
        $comms = Join-Path $script:TempRoot 'orphan'
        New-Item -ItemType Directory -Path $comms -Force | Out-Null
        $parent = Start-Process -FilePath $pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep 120' -PassThru -WindowStyle Hidden
        $worker = $null
        try {
            $workerPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Workers' 'ProcessWorker.ps1')).Path
            $worker = Start-Process -FilePath $pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', "`"$workerPath`"",
                '-ModulePath', "`"$script:FixturePsd1`"", '-ModuleName', 'FixtureModule', '-ModuleScope', 'FixtureModule',
                '-ParentPid', "$($parent.Id)", '-CommsDir', "`"$comms`"")
            $deadline = [DateTime]::Now.AddSeconds(60)
            while (-not (Test-Path (Join-Path $comms 'ready')) -and [DateTime]::Now -lt $deadline -and -not $worker.HasExited) { Start-Sleep -Milliseconds 200 }
            Test-Path (Join-Path $comms 'ready') | Should -BeTrue
            $worker.HasExited | Should -BeFalse

            $parent.Kill($true)
            $parent.WaitForExit(5000) | Out-Null
            $worker.WaitForExit(10000) | Should -BeTrue
        } finally {
            if ($worker -and -not $worker.HasExited) { $worker.Kill($true) }
            if (-not $parent.HasExited) { $parent.Kill($true) }
        }
    }
}

Describe 'Phase 2: Stop-ModuleContext' {

    BeforeEach {
        & (Get-Module Nexus) {
            $script:ModuleRunspaces = @{
                A = @{ Name = 'A'; Mode = 'runspace'; Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); Process = $null; CommsDir = $null }
                B = @{ Name = 'B'; Mode = 'runspace'; Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); Process = $null; CommsDir = $null }
            }
        }
    }

    AfterEach {
        & (Get-Module Nexus) { $script:ModuleRunspaces = @{} }
    }

    It '-Name stops only the named context' {
        $keys = & (Get-Module Nexus) { Stop-ModuleContext -Name 'A'; @($script:ModuleRunspaces.Keys) }
        $keys | Should -Be @('B')
    }

    It 'Without -Name stops every context' {
        $count = & (Get-Module Nexus) { Stop-ModuleContext; $script:ModuleRunspaces.Count }
        $count | Should -Be 0
    }

    It '-WhatIf leaves state intact' {
        $count = & (Get-Module Nexus) {
            $script:BackgroundJobs = @{ j = @{ Id = 'j'; Mode = 'process' } }
            Stop-ModuleContext -WhatIf
            Stop-ModuleContext -Name 'A' -WhatIf
            [PSCustomObject]@{ Contexts = $script:ModuleRunspaces.Count; Jobs = $script:BackgroundJobs.Count }
        }
        $count.Contexts | Should -Be 2
        $count.Jobs | Should -Be 1
        & (Get-Module Nexus) { $script:BackgroundJobs = @{} }
    }
}

Describe 'Phase 2: Register-OpsModule' {

    BeforeAll {
        $script:TestRegistry = Enter-TestRegistry -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
    }

    AfterAll {
        Exit-TestRegistry -Context $script:TestRegistry
    }

    It 'Stores a full path for a relative input' {
        Push-Location (Join-Path $PSScriptRoot 'Fixtures')
        try { Register-OpsModule -Name 'RelativeFixture' -Path (Join-Path '.' 'FixtureModule' 'FixtureModule.psd1') 6>$null }
        finally { Pop-Location }
        $reg = Get-Content $script:TestRegistry.RegistryPath -Raw | ConvertFrom-Json
        $entry = $reg.modules | Where-Object { $_.name -eq 'RelativeFixture' }
        $entry | Should -Not -BeNullOrEmpty
        [System.IO.Path]::IsPathRooted($entry.path) | Should -BeTrue
        $entry.path | Should -Not -Match '\.\.?[\\/]'
    }

    It '-WhatIf does not write the registry' {
        Register-OpsModule -Name 'WhatIfFixture' -Path $script:FixturePsd1 -WhatIf 6>$null
        $reg = Get-Content $script:TestRegistry.RegistryPath -Raw | ConvertFrom-Json
        @($reg.modules | Where-Object { $_.name -eq 'WhatIfFixture' }).Count | Should -Be 0
    }
}
