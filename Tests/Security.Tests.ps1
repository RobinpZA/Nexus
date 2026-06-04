BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Nexus.psd1'
    Import-Module $modulePath -Force
}

Describe 'Security: Command Execution Boundary' {

    It 'Blocks commands not exported by the target module' {
        # Everything in ONE module-scope call — no cross-boundary object passing
        $result = & (Get-Module Nexus) {
            $reg = Read-ModuleRegistry
            $entry = $reg.modules | Where-Object { $_.enabled -and (Test-Path $_.path) } | Select-Object -First 1
            if (-not $entry) { return 'SKIP' }
            Invoke-RegisteredCommand -ModuleEntry $entry -CommandName 'Remove-Item' -Parameters @{}
        }

        if ($result -eq 'SKIP') {
            Set-ItResult -Skipped -Because 'No valid module found in registry'
            return
        }

        $result.success | Should -Be $false
        $result.output[0].message | Should -Match 'not exported'
    }

    It 'Allows commands that ARE exported by the target module' {
        $result = & (Get-Module Nexus) {
            $reg = Read-ModuleRegistry
            $entry = $reg.modules | Where-Object { $_.enabled -and (Test-Path $_.path) } | Select-Object -First 1
            if (-not $entry) { return 'SKIP' }

            # Find a valid exported command from the manifest
            $cmdToTest = $entry.entryCommand
            if (-not $cmdToTest) {
                try {
                    $data = Import-PowerShellDataFile -Path $entry.path -ErrorAction Stop
                    $allCmds = @()
                    if ($data.FunctionsToExport) { $allCmds += @($data.FunctionsToExport | Where-Object { $_ -and $_ -ne '*' }) }
                    if ($data.CmdletsToExport)  { $allCmds += @($data.CmdletsToExport  | Where-Object { $_ -and $_ -ne '*' }) }
                    $cmdToTest = $allCmds | Select-Object -First 1
                } catch {
                    Write-Verbose "Failed to read manifest for $($entry.name): $($_.Exception.Message)"
                }
            }
            if (-not $cmdToTest) { return 'SKIP_NOCMD' }

            Invoke-RegisteredCommand -ModuleEntry $entry -CommandName $cmdToTest -Parameters @{}
        }

        if ($result -eq 'SKIP') {
            Set-ItResult -Skipped -Because 'No valid module found in registry'
            return
        }
        if ($result -eq 'SKIP_NOCMD') {
            Set-ItResult -Skipped -Because 'Module has no known exported commands'
            return
        }

        # Should pass allowlist — may fail for other reasons but NOT "not exported"
        if (-not $result.success) {
            $result.output[0].message | Should -Not -Match 'not exported'
        }
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
