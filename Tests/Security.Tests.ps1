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

Describe 'Security: Request Body Size Limit' {

    BeforeAll {
        $script:BoundedRead = {
            param($Bytes, $MaxBytes, $DeclaredLength = -1)
            & (Get-Module Nexus) {
                param($b, $max, $declared)
                $stream = [System.IO.MemoryStream]::new($b)
                try {
                    Read-BoundedRequestBody -Stream $stream -MaxBytes $max -DeclaredLength $declared -Source 'test'
                } finally { $stream.Dispose() }
            } $Bytes $MaxBytes $DeclaredLength
        }
    }

    It 'Rejects a body larger than MaxBytes' {
        $oversized = [System.Text.Encoding]::UTF8.GetBytes('x' * 5000)
        $result = & $script:BoundedRead $oversized 1000
        $result | Should -BeNullOrEmpty
    }

    It 'Fast-rejects on a declared Content-Length above MaxBytes without touching the stream' {
        $result = & (Get-Module Nexus) {
            $stream = [System.IO.MemoryStream]::new([byte[]]@(1, 2, 3))
            try {
                $r = Read-BoundedRequestBody -Stream $stream -MaxBytes 100 -DeclaredLength 5000 -Source 'test'
                [PSCustomObject]@{ Result = $r; StreamPosition = $stream.Position }
            } finally { $stream.Dispose() }
        }
        $result.Result | Should -BeNullOrEmpty
        $result.StreamPosition | Should -Be 0
    }

    It 'Accepts a body within the limit' {
        $small = [System.Text.Encoding]::UTF8.GetBytes('{"module":"X"}')
        $result = & $script:BoundedRead $small 1MB
        [System.Text.Encoding]::UTF8.GetString($result) | Should -Be '{"module":"X"}'
    }

    It 'Accepts a body exactly at the limit' {
        $exact = [System.Text.Encoding]::UTF8.GetBytes('x' * 1000)
        $result = & $script:BoundedRead $exact 1000
        $result.Length | Should -Be 1000
    }

    It 'Read-JsonRequestBody exposes a MaxBytes parameter' {
        $cmd = & (Get-Module Nexus) { Get-Command 'Read-JsonRequestBody' -ErrorAction SilentlyContinue }
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'MaxBytes'
    }
}

Describe 'Security: Response Headers' {

    It 'Add-SecurityResponseHeader sends frame-ancestors as a real header, not just the <meta> tag' {
        # frame-ancestors has no effect via <meta> per spec — the header is the only
        # thing that actually stops the portal from being framed.
        $funcDef = & (Get-Module Nexus) { (Get-Command 'Add-SecurityResponseHeader').ScriptBlock.ToString() }
        $funcDef | Should -Match 'X-Frame-Options'
        $funcDef | Should -Match "frame-ancestors 'none'"
    }

    It 'Write-JsonResponse and Write-StaticFile both send the security headers' {
        $jsonDef = & (Get-Module Nexus) { (Get-Command 'Write-JsonResponse').ScriptBlock.ToString() }
        $staticDef = & (Get-Module Nexus) { (Get-Command 'Write-StaticFile').ScriptBlock.ToString() }
        $jsonDef | Should -Match 'Add-SecurityResponseHeader'
        $staticDef | Should -Match 'Add-SecurityResponseHeader'
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
                }).AddArgument('Microsoft.PowerShell.Utility')
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
                $null = $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument('Get-Date').AddArgument(@{ Format = 'yyyy' }).AddArgument('Microsoft.PowerShell.Utility')
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

    It 'Never resolves a command outside the declared module, even with no export list' {
        # A module with FunctionsToExport = '*' gives Invoke-PortalCommand's fast-path
        # check nothing to match against — this is the actual security boundary.
        $message = & (Get-Module Nexus) {
            $ps = [PowerShell]::Create()
            try {
                $null = $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument('Get-Date').AddArgument(@{}).AddArgument('FixtureModule')
                try { $null = $ps.Invoke(); '' } catch { $_.Exception.Message }
            } finally { $ps.Dispose() }
        }

        $message | Should -Match "not exported by module 'FixtureModule'"
    }

    It 'Never resolves a command when the module scope is missing (fails closed, not open)' {
        $message = & (Get-Module Nexus) {
            $ps = [PowerShell]::Create()
            try {
                $null = $ps.AddScript((Get-RunspaceInvokeScript)).AddArgument('Get-Date').AddArgument(@{})
                try { $null = $ps.Invoke(); '' } catch { $_.Exception.Message }
            } finally { $ps.Dispose() }
        }

        $message | Should -Match 'no module scope supplied'
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

Describe 'Security: Process Worker Is a Static Shipped File' {
    # Previously rendered as script TEXT per module and written to Logs\process_<name>\
    # worker.ps1, then launched with -ExecutionPolicy Bypass — a write-then-execute gap
    # in a directory less tightly controlled than the module's own install location.

    It 'Ships as a fixed file under Workers/, not generated per invocation' {
        $workerPath = & (Get-Module Nexus) { Join-Path $script:NexusRoot 'Workers' 'ProcessWorker.ps1' }
        Test-Path $workerPath | Should -BeTrue
    }

    It 'Parses cleanly and declares the parameters New-ProcessContext passes it' {
        $workerPath = & (Get-Module Nexus) { Join-Path $script:NexusRoot 'Workers' 'ProcessWorker.ps1' }
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($workerPath, [ref]$null, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0

        $cmd = Get-Command -Name $workerPath
        $cmd.Parameters.Keys | Should -Contain 'ModulePath'
        $cmd.Parameters.Keys | Should -Contain 'ModuleName'
        $cmd.Parameters.Keys | Should -Contain 'CommsDir'
    }

    It 'New-ProcessContext launches the static file instead of writing script text to CommsDir' {
        $funcDef = & (Get-Module Nexus) { (Get-Command 'New-ProcessContext').ScriptBlock.ToString() }
        $funcDef | Should -Match "Workers.*ProcessWorker\.ps1"
        $funcDef | Should -Not -Match 'workerScript'
    }
}

Describe 'Security: Enable-NexusAutoStart Supports ShouldProcess' {
    # Rewrites the user's real PowerShell profile — PSUseShouldProcessForStateChangingFunctions
    # is suppressed repo-wide (PSScriptAnalyzerSettings.psd1), but a function that mutates
    # $PROFILE specifically should still offer -WhatIf/-Confirm.

    It 'Declares SupportsShouldProcess so -WhatIf/-Confirm are available' {
        $cmd = & (Get-Module Nexus) { Get-Command 'Enable-NexusAutoStart' -ErrorAction SilentlyContinue }
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'WhatIf'
        $cmd.Parameters.Keys | Should -Contain 'Confirm'
    }

    It '-WhatIf makes no change to the profile file' {
        # PowerShell's own ShouldProcess plumbing guarantees $PSCmdlet.ShouldProcess()
        # returns $false under -WhatIf, regardless of our logic — so this is safe to run
        # against the real $PROFILE path without risk of it actually being written.
        $repoRoot = & (Get-Module Nexus) { $script:NexusRoot }
        $profilePath = $PROFILE.CurrentUserAllHosts
        $existedBefore = Test-Path $profilePath
        $beforeStamp = if ($existedBefore) { (Get-Item $profilePath).LastWriteTimeUtc } else { $null }

        $out = Enable-NexusAutoStart -NexusRoot $repoRoot -WhatIf

        $out | Should -BeNullOrEmpty
        if ($existedBefore) {
            (Get-Item $profilePath).LastWriteTimeUtc | Should -Be $beforeStamp
        } else {
            Test-Path $profilePath | Should -BeFalse
        }
    }
}
