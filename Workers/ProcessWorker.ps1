<#
.SYNOPSIS
    Nexus process-isolation worker. Imports one module and answers commands over a
    file-based channel until told to exit.
.DESCRIPTION
    SECURITY: This file ships as part of the Nexus module (read-only, versioned) and is
    launched directly via -File, with the per-invocation values passed as parameters.
    It previously existed only as script TEXT rendered per module and written to
    Logs\process_<name>\worker.ps1, then launched with -ExecutionPolicy Bypass — a
    write-then-execute gap in a directory that isn't necessarily as tightly protected as
    the module's own install location. Running this fixed, shipped file instead closes
    that window; nothing writes PowerShell source into the comms directory anymore.
.PARAMETER ModulePath
    Path to the target module's manifest (.psd1).
.PARAMETER ModuleName
    The module's registry name — used for window title, module-scoped Get-Command, and
    log lines.
.PARAMETER CommsDir
    Directory holding the command/response files and the reflection scripts
    (meta.ps1/synopsis.ps1/connection.ps1) that New-ProcessContext writes alongside it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModulePath,
    [Parameter(Mandatory)][string]$ModuleName,
    [Parameter(Mandatory)][string]$CommsDir
)

$Host.UI.RawUI.WindowTitle = "Nexus: $ModuleName"
$ErrorActionPreference = 'Continue'

$commandFile      = Join-Path $CommsDir 'command.json'
$responseFile     = Join-Path $CommsDir 'response.json'
$readyFile        = Join-Path $CommsDir 'ready'
$exitFile         = Join-Path $CommsDir 'exit'
$metaScript       = Join-Path $CommsDir 'meta.ps1'
$synopsisScript   = Join-Path $CommsDir 'synopsis.ps1'
$connectionScript = Join-Path $CommsDir 'connection.ps1'

Write-Host "Nexus Process: $ModuleName" -ForegroundColor Cyan
Write-Host "Importing module..." -ForegroundColor DarkGray

try {
    Import-Module $ModulePath -Force -DisableNameChecking -ErrorAction Stop
    [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace = $Host.Runspace
    Write-Host "Module loaded." -ForegroundColor Green
    'ready' | Out-File $readyFile -Encoding utf8
} catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $_.Exception.Message | Out-File $readyFile -Encoding utf8
    Start-Sleep -Seconds 10
    return
}

Write-Host "Waiting for commands..." -ForegroundColor DarkGray
Write-Host ""

while (-not (Test-Path $exitFile)) {
    if (Test-Path $commandFile) {
        try {
            $req = Get-Content $commandFile -Raw -Encoding utf8 | ConvertFrom-Json
            Remove-Item $commandFile -Force

            $cmd = $req.command

            if ($req.mode -in @('params', 'synopsis', 'connection')) {
                Write-Host "? metadata ($($req.mode))" -ForegroundColor DarkGray
                try {
                    $script = switch ($req.mode) {
                        'params'     { $metaScript }
                        'synopsis'   { $synopsisScript }
                        'connection' { $connectionScript }
                    }
                    $meta = & $script $cmd
                    @{success=$true; metadata=$meta; durationMs=0} |
                        ConvertTo-Json -Depth 8 -Compress |
                        Out-File $responseFile -Encoding utf8 -Force
                } catch {
                    @{success=$false; output=@(@{stream='Error'; message=$_.Exception.Message}); durationMs=0} |
                        ConvertTo-Json -Depth 5 -Compress |
                        Out-File $responseFile -Encoding utf8 -Force
                }
                continue
            }

            Write-Host "> $cmd" -ForegroundColor Yellow

            $params = @{}
            if ($req.parameters) { $req.parameters.PSObject.Properties | ForEach-Object { $params[$_.Name] = $_.Value } }

            # SECURITY: scoped to the one module this worker imported — an unscoped
            # Get-Command would also resolve every default-session cmdlet (Remove-Item,
            # Invoke-Expression, ...). See Get-RunspaceInvokeScript in
            # Invoke-InRunspace.ps1 for the runspace-mode equivalent of this check.
            $cmdInfo = Get-Command $cmd -Module $ModuleName -ErrorAction SilentlyContinue
            if (-not $cmdInfo) { throw "Command '$cmd' is not exported by module '$ModuleName'." }

            $boundParams = @{}
            foreach ($key in $params.Keys) {
                $val = $params[$key]
                $pInfo = $cmdInfo.Parameters[$key]
                if ($pInfo -and $pInfo.ParameterType -eq [switch]) {
                    if ($val -eq $true -or $val -eq 'true' -or $val -eq 'True') { $boundParams[$key] = [switch]$true }
                } else { $boundParams[$key] = $val }
            }

            $output = [System.Collections.Generic.List[object]]::new()
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $result = & $cmdInfo @boundParams *>&1
                foreach ($item in $result) {
                    $stream = switch ($item.GetType().Name) {
                        'ErrorRecord' {'Error'} 'WarningRecord' {'Warning'}
                        'InformationRecord' {'Information'} default {'Success'}
                    }
                    $output.Add(@{stream=$stream; message=$item.ToString()})
                    $color = switch ($stream) { 'Error' {'Red'} 'Warning' {'Yellow'} 'Information' {'Cyan'} default {'White'} }
                    Write-Host "  [$stream] $($item.ToString())" -ForegroundColor $color
                }
                $ok = $true
                Write-Host "  Done ($([math]::Round($sw.Elapsed.TotalMilliseconds))ms)" -ForegroundColor Green
            } catch {
                $output.Add(@{stream='Error'; message=$_.Exception.Message})
                Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
                $ok = $false
            }
            $sw.Stop()

            @{success=$ok; output=$output; durationMs=[math]::Round($sw.Elapsed.TotalMilliseconds)} |
                ConvertTo-Json -Depth 5 -Compress |
                Out-File $responseFile -Encoding utf8 -Force
        } catch {
            @{success=$false; output=@(@{stream='Error'; message=$_.Exception.Message}); durationMs=0} |
                ConvertTo-Json -Depth 5 -Compress |
                Out-File $responseFile -Encoding utf8 -Force
        }
    }
    Start-Sleep -Milliseconds 200
}
Write-Host "`nExiting." -ForegroundColor DarkGray
