<#
.SYNOPSIS
    Nexus build script — Analyse, Test, Build.
.PARAMETER Task
    The task to run: Analyze, Test, Build, CI (all), Clean.
.EXAMPLE
    .\build.ps1 -Task CI
#>
param(
    [ValidateSet('Analyze', 'Test', 'Build', 'CI', 'Clean')]
    [string]$Task = 'CI'
)

$moduleName = 'Nexus'
$buildDir   = Join-Path $PSScriptRoot 'build' $moduleName

switch ($Task) {
    'Analyze' {
        Write-Host '─── PSScriptAnalyzer ───' -ForegroundColor Cyan
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        # Analyse sources only — build/ holds copies that would be reported twice.
        $results = @()
        foreach ($folder in @('Private', 'Public', 'Tests', 'Workers')) {
            $path = Join-Path $PSScriptRoot $folder
            if (Test-Path $path) {
                $results += Invoke-ScriptAnalyzer -Path $path -Recurse -Settings "$PSScriptRoot\PSScriptAnalyzerSettings.psd1" -ExcludeRule PSUseToExportFieldsInManifest
            }
        }
        $results += Invoke-ScriptAnalyzer -Path "$PSScriptRoot\Nexus.psm1" -Settings "$PSScriptRoot\PSScriptAnalyzerSettings.psd1" -ExcludeRule PSUseToExportFieldsInManifest
        $results | Format-Table -AutoSize
        $errors = $results | Where-Object Severity -eq 'Error'
        if ($errors) {
            Write-Host "  ✗ $($errors.Count) error(s) found" -ForegroundColor Red
            throw 'PSScriptAnalyzer found errors'
        } else {
            Write-Host '  ✓ No errors' -ForegroundColor Green
        }
    }
    'Test' {
        Write-Host '─── Pester Tests ───' -ForegroundColor Cyan
        Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
        $config = New-PesterConfiguration
        $config.Run.Path = "$PSScriptRoot\Tests"
        $config.Output.Verbosity = 'Detailed'
        $config.TestResult.Enabled = $true
        $config.TestResult.OutputPath = "$PSScriptRoot\build\TestResults.xml"
        $config.Run.PassThru = $true
        # Keep local runs off the real %LOCALAPPDATA%\Nexus: the module reads NEXUS_HOME at import.
        $previousHome = $env:NEXUS_HOME
        $tempHome = $null
        if (-not $env:NEXUS_HOME) {
            $tempHome = Join-Path ([System.IO.Path]::GetTempPath()) "nexus-test-home-$([guid]::NewGuid().ToString('N'))"
            $env:NEXUS_HOME = $tempHome
        }
        try {
            $result = Invoke-Pester -Configuration $config
        } finally {
            $env:NEXUS_HOME = $previousHome
            if ($tempHome -and (Test-Path $tempHome)) { Remove-Item $tempHome -Recurse -Force -ErrorAction SilentlyContinue }
        }
        # Without this the CI task reported success with failing tests. Container failures
        # (a test file that fails to load or in BeforeAll) leave FailedCount at 0.
        $failedContainers = @($result.Containers | Where-Object Result -eq 'Failed')
        if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0 -or $result.Result -ne 'Passed') {
            foreach ($container in $failedContainers) {
                Write-Host "  Failed container: $($container.Name)" -ForegroundColor Red
            }
            throw "Pester run failed: $($result.FailedCount) test(s), $($result.FailedContainersCount) container(s), result '$($result.Result)'"
        }
    }
    'Build' {
        Write-Host '─── Build ───' -ForegroundColor Cyan
        if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
        New-Item $buildDir -ItemType Directory -Force | Out-Null
        $items = @('Public', 'Private', 'Workers', 'Assets', 'Config', "$moduleName.psd1", "$moduleName.psm1", "$moduleName.Format.ps1xml")
        foreach ($item in $items) {
            $src = Join-Path $PSScriptRoot $item
            if (Test-Path $src) {
                Copy-Item $src -Destination $buildDir -Recurse -Force
            }
        }
        Write-Host "  ✓ Build output: $buildDir" -ForegroundColor Green
    }
    'CI' {
        & $PSScriptRoot\build.ps1 -Task Analyze
        & $PSScriptRoot\build.ps1 -Task Test
        & $PSScriptRoot\build.ps1 -Task Build
    }
    'Clean' {
        $cleanDir = Join-Path $PSScriptRoot 'build'
        if (Test-Path $cleanDir) { Remove-Item $cleanDir -Recurse -Force }
        $logsDir = Join-Path $PSScriptRoot 'Logs'
        if (Test-Path $logsDir) { Get-ChildItem $logsDir -Filter '*.log' | Remove-Item -Force }
        Write-Host '  ✓ Cleaned.' -ForegroundColor Green
    }
}
