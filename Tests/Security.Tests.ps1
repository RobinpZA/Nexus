BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Nexus.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestRegistry.ps1')
    # A fixture registry: these tests execute commands, and must never reach a live tenant.
    $script:TestRegistry = Enter-TestRegistry -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
}

AfterAll {
    Exit-TestRegistry -Context $script:TestRegistry
}

Describe 'Security: Command Execution Boundary' {

    It 'Blocks commands not exported by the target module' {
        $result = & (Get-Module Nexus) {
            $entry = (Read-ModuleRegistry).modules | Where-Object { $_.name -eq 'FixtureModule' }
            Invoke-RegisteredCommand -ModuleEntry $entry -CommandName 'Remove-Item' -Parameters @{}
        }

        $result.success | Should -BeFalse
        $result.output[0].message | Should -Match 'not exported'
    }

    It 'Runs a command the module does export' {
        $result = & (Get-Module Nexus) {
            $entry = (Read-ModuleRegistry).modules | Where-Object { $_.name -eq 'FixtureModule' }
            Invoke-RegisteredCommand -ModuleEntry $entry -CommandName 'Get-FixtureValue' -Parameters @{ Text = 'ok'; Choice = 'two' }
        }

        $result.success | Should -BeTrue
        $result.output[0].message | Should -Be 'ok/two'
    }

    It 'Treats the string "false" as a switch that is off' {
        $result = & (Get-Module Nexus) {
            $entry = (Read-ModuleRegistry).modules | Where-Object { $_.name -eq 'FixtureModule' }
            Invoke-RegisteredCommand -ModuleEntry $entry -CommandName 'Get-FixtureValue' -Parameters @{ Text = 'ok'; Loud = 'false' }
        }

        $result.output[0].message | Should -Be 'ok/one'   # not 'OK/ONE'
    }

    It 'Reports a failing command as failed' {
        $result = & (Get-Module Nexus) {
            $entry = (Read-ModuleRegistry).modules | Where-Object { $_.name -eq 'FixtureModule' }
            Invoke-RegisteredCommand -ModuleEntry $entry -CommandName 'Write-FixtureFailure' -Parameters @{}
        }

        $result.success | Should -BeFalse
        ($result.output | Where-Object stream -eq 'Error').message | Should -Match 'fixture failure'
    }
}

Describe 'Security: Static File Path Traversal' {

    It 'Write-StaticFile blocks directory traversal attempts' {
        $portalRoot = & (Get-Module Nexus) { $script:PortalRoot }
        $portalRootFull = [System.IO.Path]::GetFullPath($portalRoot).TrimEnd('\', '/')
        $traversalPath  = '../../Config/modules.json'
        $resolvedPath   = [System.IO.Path]::GetFullPath((Join-Path $portalRoot $traversalPath))
        $resolvedPath.StartsWith($portalRootFull, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be $false
    }

    It 'Write-StaticFile allows valid portal paths' {
        $portalRoot = & (Get-Module Nexus) { $script:PortalRoot }
        $portalRootFull = [System.IO.Path]::GetFullPath($portalRoot).TrimEnd('\', '/')
        $validPath    = 'css/style.css'
        $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $portalRoot $validPath))
        $resolvedPath.StartsWith($portalRootFull, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be $true
    }
}

Describe 'Security: Error Response Sanitisation' {

    It 'Write-ErrorResponse does not expose internal details for 500 errors' {
        $cmd = & (Get-Module Nexus) { Get-Command 'Write-ErrorResponse' -ErrorAction SilentlyContinue }
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'InternalDetail'
    }
}

Describe 'Security: CORS Headers' {

    It 'Write-JsonResponse does not add Access-Control-Allow-Origin header' {
        $funcDef = & (Get-Module Nexus) { (Get-Command 'Write-JsonResponse').ScriptBlock.ToString() }
        $funcDef | Should -Not -Match 'Access-Control-Allow-Origin'
    }
}

Describe 'Security: Cross-Site Request Guard' {

    BeforeAll {
        $script:Expected = 'http://127.0.0.1:8090'
        $script:Check = {
            param($Method, $Origin, $Referer, $ContentType)
            & (Get-Module Nexus) {
                param($m, $o, $r, $c, $e)
                Test-SameOriginRequest -Method $m -ExpectedOrigin $e -Origin $o -Referer $r -ContentType $c
            } $Method $Origin $Referer $ContentType $script:Expected
        }
    }

    It 'Allows GET regardless of origin' {
        & $script:Check 'GET' 'http://evil.test' '' '' | Should -BeTrue
    }

    It 'Allows POST from the portal itself' {
        & $script:Check 'POST' 'http://127.0.0.1:8090' '' 'application/json' | Should -BeTrue
    }

    It 'Blocks POST from another origin' {
        & $script:Check 'POST' 'http://evil.test' '' 'application/json' | Should -BeFalse
    }

    It 'Blocks POST whose Referer is another site' {
        & $script:Check 'POST' '' 'http://evil.test/page.html' 'application/json' | Should -BeFalse
    }

    It 'Blocks the cross-site form POST (text/plain, no Origin)' {
        # <form action="http://127.0.0.1:8090/api/execute" method="POST" enctype="text/plain">
        & $script:Check 'POST' '' '' 'text/plain' | Should -BeFalse
    }

    It 'Blocks a bodyless DELETE with no Origin or Referer' {
        & $script:Check 'DELETE' '' '' '' | Should -BeFalse
    }

    It 'Allows a JSON request from a CLI client (no Origin, no Referer)' {
        & $script:Check 'POST' '' '' 'application/json; charset=utf-8' | Should -BeTrue
    }
}

Describe 'Security: Runspace Parameter Binding' {

    It 'Rejects a parameter name carrying injected script' {
        $message = & (Get-Module Nexus) {
            $ps = [PowerShell]::Create()
            try {
                $null = $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument('Get-Date').AddArgument(@{
                    'Format; New-Item -Path $env:TEMP\nexus_pwned.txt -ItemType File' = 'yyyy'
                })
                try { $null = $ps.Invoke(); '' } catch { $_.Exception.Message }
            } finally { $ps.Dispose() }
        }

        $message | Should -Match 'is not valid for command'
        Test-Path (Join-Path $env:TEMP 'nexus_pwned.txt') | Should -BeFalse
    }

    It 'Binds legitimate parameters by name' {
        $result = & (Get-Module Nexus) {
            $ps = [PowerShell]::Create()
            try {
                $null = $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument('Get-Date').AddArgument(@{ Format = 'yyyy' })
                @($ps.Invoke())[0]
            } finally { $ps.Dispose() }
        }

        $result | Should -Be (Get-Date -Format 'yyyy')
    }

    It 'Does not build the command line by string concatenation' {
        $script = & (Get-Module Nexus) { Get-RunspaceInvokeScript }
        $script | Should -Match '@bound'
        $script | Should -Not -Match '\$CommandName\$'
    }
}

Describe 'Security: Settings Merge Validation' {

    BeforeAll {
        $script:Current = [PSCustomObject]@{
            defaultPort       = 8090
            portRange         = @(8090, 8099)
            scanRoots         = @('C:\Modules')
            scanOnStartup     = $false
            favouriteCommands = @(@{ module = 'M'; command = 'C' })
            maxRecentCommands = 20
        }
        $script:Merge = {
            param($Incoming)
            & (Get-Module Nexus) {
                param($cur, $inc)
                Merge-HubSettings -Current $cur -Incoming $inc
            } $script:Current $Incoming
        }
    }

    It 'Keeps existing values when the payload is empty' {
        $merged = & $script:Merge ([PSCustomObject]@{})
        @($merged.scanRoots).Count | Should -Be 1
        @($merged.favouriteCommands).Count | Should -Be 1
        $merged.defaultPort | Should -Be 8090
    }

    It 'Applies a known key without touching the others' {
        $merged = & $script:Merge ([PSCustomObject]@{ scanOnStartup = $true })
        $merged.scanOnStartup | Should -BeTrue
        @($merged.scanRoots).Count | Should -Be 1
    }

    It 'Ignores unknown keys' {
        $merged = & $script:Merge ([PSCustomObject]@{ evilKey = 'value' })
        $merged.PSObject.Properties.Name | Should -Not -Contain 'evilKey'
    }

    It 'Never accepts favourites from a settings payload' {
        $merged = & $script:Merge ([PSCustomObject]@{ favouriteCommands = @() })
        @($merged.favouriteCommands).Count | Should -Be 1
    }

    It 'Rejects an out-of-range port' {
        { & $script:Merge ([PSCustomObject]@{ defaultPort = 70000 }) } | Should -Throw '*between 1 and 65535*'
    }

    It 'Rejects a non-boolean flag' {
        { & $script:Merge ([PSCustomObject]@{ scanOnStartup = 'maybe' }) } | Should -Throw '*expected a boolean*'
    }

    It 'Treats the string "false" as false, not true' {
        $merged = & $script:Merge ([PSCustomObject]@{ scanOnStartup = 'false' })
        $merged.scanOnStartup | Should -BeFalse
    }
}
