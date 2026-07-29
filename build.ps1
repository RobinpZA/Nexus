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
        foreach ($folder in @('Private', 'Public', 'Tests')) {
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
        $result = Invoke-Pester -Configuration $config
        # Without this the CI task reported success with failing tests.
        if ($result.FailedCount -gt 0) {
            throw "$($result.FailedCount) test(s) failed"
        }
    }
    'Build' {
        Write-Host '─── Build ───' -ForegroundColor Cyan
        if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
        New-Item $buildDir -ItemType Directory -Force | Out-Null
        $items = @('Public', 'Private', 'Assets', 'Config', "$moduleName.psd1", "$moduleName.psm1")
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
