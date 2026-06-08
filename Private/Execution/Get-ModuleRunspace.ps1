function Get-ModuleRunspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [switch]$Force
    )

    if (-not $script:ModuleRunspaces) { $script:ModuleRunspaces = @{} }
    $name = $ModuleEntry.name
    $mode = Get-RequiredIsolationMode -ModuleEntry $ModuleEntry

    if (-not $Force -and $script:ModuleRunspaces.ContainsKey($name)) {
        $existing = $script:ModuleRunspaces[$name]
        if ($existing.Mode -eq 'process' -and $existing.Process -and -not $existing.Process.HasExited) {
            Write-HubLog -Level Debug -Message "Reusing process for: $name (PID $($existing.Process.Id))"
            return $existing
        }
        if ($existing.Mode -eq 'runspace' -and $existing.Runspace -and $existing.Runspace.RunspaceStateInfo.State -eq 'Opened') {
            Write-HubLog -Level Debug -Message "Reusing runspace for: $name"
            return $existing
        }
        try {
            if ($existing.Process -and -not $existing.Process.HasExited) { $existing.Process.Kill() }
            if ($existing.Runspace) { $existing.Runspace.Dispose() }
            if ($existing.CommsDir -and (Test-Path $existing.CommsDir)) { Remove-Item $existing.CommsDir -Recurse -Force -ErrorAction SilentlyContinue }
        } catch {
            Write-HubLog -Level Debug -Message "Failed to clean stale context for $name : $($_.Exception.Message)"
        }
        $script:ModuleRunspaces.Remove($name)
    }

    if ($mode -eq 'process') { return New-ProcessContext -ModuleEntry $ModuleEntry }
    else { return New-RunspaceContext -ModuleEntry $ModuleEntry }
}

function Get-RequiredIsolationMode {
    param([object]$ModuleEntry)

    # ── 1. Check for explicit override in modules.json ──
    # Set "isolation": "process" or "isolation": "runspace" per module
    if ($ModuleEntry.PSObject.Properties.Name -contains 'isolation' -and $ModuleEntry.isolation) {
        $override = $ModuleEntry.isolation.ToLower()
        if ($override -in @('process', 'runspace')) {
            Write-HubLog -Level Debug -Message "Isolation override for $($ModuleEntry.name): $override"
            return $override
        }
    }

    # ── 2. Check module name against known conflict list ──
    $conflictPrefixes = @(
        'Microsoft.Graph', 'ExchangeOnlineManagement', 'Az.', 'Az',
        'MicrosoftTeams', 'Microsoft.Online.SharePoint', 'PnP.PowerShell',
        'MSIdentityTools', 'Maester', 'MSOnline'
    )

    foreach ($prefix in $conflictPrefixes) {
        if ($ModuleEntry.name -eq $prefix -or $ModuleEntry.name.StartsWith("$prefix.")) { return 'process' }
    }

    # ── 3. Check RequiredModules in manifest ──
    $deps = @()
    if (Test-Path $ModuleEntry.path) {
        try {
            $data = Import-PowerShellDataFile -Path $ModuleEntry.path -ErrorAction SilentlyContinue
            if ($data.RequiredModules) {
                $deps = @($data.RequiredModules | ForEach-Object {
                    if ($_ -is [string]) { $_ } elseif ($_ -is [hashtable] -and $_.ModuleName) { $_.ModuleName } else { $_.ToString() }
                })
            }
        } catch {
            Write-HubLog -Level Debug -Message "Failed to read RequiredModules for $($ModuleEntry.name) : $($_.Exception.Message)"
        }
    }

    foreach ($dep in $deps) {
        foreach ($prefix in $conflictPrefixes) {
            if ($dep -eq $prefix -or $dep.StartsWith("$prefix.")) {
                Write-HubLog -Level Info -Message "Process isolation for $($ModuleEntry.name) (RequiredModules: $dep)"
                return 'process'
            }
        }
    }

    # ── 4. Scan the .psm1 for internal imports of Graph/EXO/Teams ──
    # Custom modules often Import-Module Microsoft.Graph.Authentication inside their .psm1
    # without declaring it in RequiredModules
    $psm1Path = $ModuleEntry.path -replace '\.psd1$', '.psm1'
    if (Test-Path $psm1Path) {
        try {
            $psm1Content = Get-Content $psm1Path -Raw -ErrorAction SilentlyContinue
            if ($psm1Content) {
                $scanPatterns = @(
                    'Microsoft\.Graph',
                    'ExchangeOnlineManagement',
                    'MicrosoftTeams',
                    'Connect-MgGraph',
                    'Connect-ExchangeOnline',
                    'Connect-MicrosoftTeams',
                    'Connect-IPPSSession',
                    'Az\.Accounts',
                    'PnP\.PowerShell',
                    'Connect-PnPOnline'
                )
                foreach ($pattern in $scanPatterns) {
                    if ($psm1Content -match $pattern) {
                        Write-HubLog -Level Info -Message "Process isolation for $($ModuleEntry.name) (psm1 references: $pattern)"
                        return 'process'
                    }
                }
            }
        } catch {
            Write-HubLog -Level Debug -Message "Failed to scan psm1 for $($ModuleEntry.name) : $($_.Exception.Message)"
        }
    }

    # ── 5. Also scan nested .ps1 files in the module folder (Private/, Public/) ──
    $moduleFolder = Split-Path $ModuleEntry.path -Parent
    if (Test-Path $moduleFolder) {
        $ps1Files = @(Get-ChildItem -Path $moduleFolder -Filter '*.ps1' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 20)
        foreach ($ps1 in $ps1Files) {
            try {
                $content = Get-Content $ps1.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -match 'Connect-MgGraph|Connect-ExchangeOnline|Connect-MicrosoftTeams|Microsoft\.Graph\.Authentication|Connect-IPPSSession|Connect-PnPOnline') {
                    Write-HubLog -Level Info -Message "Process isolation for $($ModuleEntry.name) (found Graph/EXO/Teams ref in $($ps1.Name))"
                    return 'process'
                }
            } catch {
                Write-HubLog -Level Debug -Message "Failed to scan $($ps1.FullName) for $($ModuleEntry.name) : $($_.Exception.Message)"
            }
        }
    }

    return 'runspace'
}

function New-RunspaceContext {
    param([object]$ModuleEntry)
    $name = $ModuleEntry.name
    Write-HubLog -Level Info -Message "Creating runspace for: $name"

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $runspace.Name = "Nexus_$name"
    try { $runspace.Open() } catch {
        Write-HubLog -Level Error -Message "Failed to open runspace for $name : $($_.Exception.Message)"
        return $null
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    try {
        $ps.AddScript("Import-Module '$($ModuleEntry.path -replace "'","''")' -Force -DisableNameChecking") | Out-Null
        $null = $ps.Invoke()
    } catch {
        Write-HubLog -Level Error -Message "Failed to import $name : $($_.Exception.Message)"
        $runspace.Dispose(); return $null
    } finally { $ps.Dispose() }

    $entry = @{
        Name = $name; Mode = 'runspace'; Runspace = $runspace; Process = $null
        ModulePath = $ModuleEntry.path; CreatedAt = Get-Date; Connected = $false; LastUsed = Get-Date
        CommsDir = $null; ActiveAsyncJobId = $null
    }
    $script:ModuleRunspaces[$name] = $entry
    Write-HubLog -Level Info -Message "Runspace ready: $name"
    return $entry
}

function New-ProcessContext {
    param([object]$ModuleEntry)
    $name = $ModuleEntry.name
    Write-HubLog -Level Info -Message "Creating PROCESS for: $name (full DLL isolation)"

    $commsDir = Join-Path $script:LogDir "process_$($name -replace '[^a-zA-Z0-9_-]','_')"
    if (Test-Path $commsDir) { Remove-Item $commsDir -Recurse -Force }
    New-Item $commsDir -ItemType Directory -Force | Out-Null

    $commandFile  = Join-Path $commsDir 'command.json'
    $responseFile = Join-Path $commsDir 'response.json'
    $readyFile    = Join-Path $commsDir 'ready'
    $exitFile     = Join-Path $commsDir 'exit'

    $escapedModPath = $ModuleEntry.path -replace "'", "''"
    $escapedCommsDir = $commsDir -replace "'", "''"

    $workerScript = @"
`$host.UI.RawUI.WindowTitle = 'Nexus: $name'
`$ErrorActionPreference = 'Continue'
`$commsDir = '$escapedCommsDir'
`$commandFile  = Join-Path `$commsDir 'command.json'
`$responseFile = Join-Path `$commsDir 'response.json'
`$readyFile    = Join-Path `$commsDir 'ready'
`$exitFile     = Join-Path `$commsDir 'exit'

Write-Host "Nexus Process: $name" -ForegroundColor Cyan
Write-Host "Importing module..." -ForegroundColor DarkGray

try {
    Import-Module '$escapedModPath' -Force -DisableNameChecking -ErrorAction Stop
    [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace = `$host.Runspace
    Write-Host "Module loaded." -ForegroundColor Green
    'ready' | Out-File `$readyFile -Encoding utf8
} catch {
    Write-Host "FAILED: `$(`$_.Exception.Message)" -ForegroundColor Red
    `$_.Exception.Message | Out-File `$readyFile -Encoding utf8
    Start-Sleep -Seconds 10
    return
}

Write-Host "Waiting for commands..." -ForegroundColor DarkGray
Write-Host ""

while (-not (Test-Path `$exitFile)) {
    if (Test-Path `$commandFile) {
        try {
            `$req = Get-Content `$commandFile -Raw -Encoding utf8 | ConvertFrom-Json
            Remove-Item `$commandFile -Force

            `$cmd = `$req.command
            Write-Host "> `$cmd" -ForegroundColor Yellow

            `$params = @{}
            if (`$req.parameters) { `$req.parameters.PSObject.Properties | ForEach-Object { `$params[`$_.Name] = `$_.Value } }

            `$cmdInfo = Get-Command `$cmd -ErrorAction Stop
            `$boundParams = @{}
            foreach (`$key in `$params.Keys) {
                `$val = `$params[`$key]
                `$pInfo = `$cmdInfo.Parameters[`$key]
                if (`$pInfo -and `$pInfo.ParameterType -eq [switch]) {
                    if (`$val -eq `$true -or `$val -eq 'true' -or `$val -eq 'True') { `$boundParams[`$key] = [switch]`$true }
                } else { `$boundParams[`$key] = `$val }
            }

            `$output = [System.Collections.Generic.List[object]]::new()
            `$sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                `$result = & `$cmdInfo @boundParams *>&1
                foreach (`$item in `$result) {
                    `$stream = switch (`$item.GetType().Name) {
                        'ErrorRecord' {'Error'} 'WarningRecord' {'Warning'}
                        'InformationRecord' {'Information'} default {'Success'}
                    }
                    `$output.Add(@{stream=`$stream; message=`$item.ToString()})
                    `$color = switch (`$stream) { 'Error' {'Red'} 'Warning' {'Yellow'} 'Information' {'Cyan'} default {'White'} }
                    Write-Host "  [`$stream] `$(`$item.ToString())" -ForegroundColor `$color
                }
                `$ok = `$true
                Write-Host "  Done (`$([math]::Round(`$sw.Elapsed.TotalMilliseconds))ms)" -ForegroundColor Green
            } catch {
                `$output.Add(@{stream='Error'; message=`$_.Exception.Message})
                Write-Host "  ERROR: `$(`$_.Exception.Message)" -ForegroundColor Red
                `$ok = `$false
            }
            `$sw.Stop()

            @{success=`$ok; output=`$output; durationMs=[math]::Round(`$sw.Elapsed.TotalMilliseconds)} |
                ConvertTo-Json -Depth 5 -Compress |
                Out-File `$responseFile -Encoding utf8 -Force
        } catch {
            @{success=`$false; output=@(@{stream='Error'; message=`$_.Exception.Message}); durationMs=0} |
                ConvertTo-Json -Depth 5 -Compress |
                Out-File `$responseFile -Encoding utf8 -Force
        }
    }
    Start-Sleep -Milliseconds 200
}
Write-Host "`nExiting." -ForegroundColor DarkGray
"@

    $workerPath = Join-Path $commsDir 'worker.ps1'
    $workerScript | Out-File $workerPath -Encoding utf8 -Force

    $pwshPath = (Get-Process -Id $PID).Path
    $proc = Start-Process -FilePath $pwshPath `
        -ArgumentList "-NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$workerPath`"" `
        -WindowStyle Minimized `
        -PassThru

    Write-HubLog -Level Info -Message "Process started: $name (PID $($proc.Id))"

    $timeout = [DateTime]::Now.AddSeconds(60)
    while ([DateTime]::Now -lt $timeout) {
        if ($proc.HasExited) {
            Write-HubLog -Level Error -Message "Process for $name exited prematurely"
            return $null
        }
        if (Test-Path $readyFile) {
            $readyContent = (Get-Content $readyFile -Raw).Trim()
            Remove-Item $readyFile -Force -ErrorAction SilentlyContinue
            if ($readyContent -eq 'ready') { break }
            else {
                Write-HubLog -Level Error -Message "Process import failed for $name : $readyContent"
                try { $proc.Kill() } catch { Write-HubLog -Level Debug -Message "Failed to terminate process for $name : $($_.Exception.Message)" }
                return $null
            }
        }
        Start-Sleep -Milliseconds 300
    }

    Write-HubLog -Level Info -Message "Process ready: $name (PID $($proc.Id))"

    $entry = @{
        Name = $name; Mode = 'process'; Runspace = $null; Process = $proc
        ModulePath = $ModuleEntry.path; CreatedAt = Get-Date; Connected = $false; LastUsed = Get-Date
        CommsDir = $commsDir; CommandFile = $commandFile; ResponseFile = $responseFile; ExitFile = $exitFile
        ActiveAsyncJobId = $null
    }
    $script:ModuleRunspaces[$name] = $entry
    return $entry
}
