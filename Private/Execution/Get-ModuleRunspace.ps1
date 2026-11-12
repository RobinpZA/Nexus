function Get-ModuleRunspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [switch]$Force
    )

    if (-not $script:ModuleRunspaces) { $script:ModuleRunspaces = @{} }
    $name = $ModuleEntry.name

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
            if ($existing.Process -and -not $existing.Process.HasExited) { $existing.Process.Kill($true) }
            if ($existing.Process -is [System.IDisposable]) { $existing.Process.Dispose() }
            if ($existing.Runspace) { $existing.Runspace.Dispose() }
            if ($existing.CommsDir -and (Test-Path $existing.CommsDir)) { Remove-Item $existing.CommsDir -Recurse -Force -ErrorAction SilentlyContinue }
        } catch {
            Write-HubLog -Level Debug -Message "Failed to clean stale context for $name : $($_.Exception.Message)"
        }
        $script:ModuleRunspaces.Remove($name)
    }

    # Only a new context needs the (expensive) isolation decision.
    $mode = Get-RequiredIsolationMode -ModuleEntry $ModuleEntry
    if ($mode -eq 'process') { return New-ProcessContext -ModuleEntry $ModuleEntry }
    else { return New-RunspaceContext -ModuleEntry $ModuleEntry }
}

function Get-ModuleScopeName {
    <#
    .SYNOPSIS
        Returns the name the loaded module is known by, for scoping Get-Command.
    .DESCRIPTION
        A module loads under its manifest's base name, which can differ from the
        friendly name chosen at registration.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .EXAMPLE
        Get-ModuleScopeName -ModuleEntry $mod
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ModuleEntry)

    $path = [string]$ModuleEntry.path
    if ($path -match '\.(psd1|psm1)$') { return [System.IO.Path]::GetFileNameWithoutExtension($path) }
    return Split-Path $path.TrimEnd('\', '/') -Leaf
}

function Remove-ModuleContext {
    <#
    .SYNOPSIS
        Discards a module context: kills its worker process tree and removes its comms folder.
    .DESCRIPTION
        Used when a process worker stops answering, or a job is cancelled. The worker
        keeps running and would write a late response, so the whole context is dropped
        and the next call builds a fresh one. Releases the context's busy flag.

        The process is killed without a long wait for it to exit (a blocking wait would
        stall the listener thread).

        A runspace context is closed with CloseAsync (non-blocking): a pipeline stuck in
        a call PowerShell cannot interrupt would make a synchronous Dispose hang the
        listener thread.
    .PARAMETER Context
        The context entry to discard.
    .PARAMETER JobId
        The job being reaped. When given, the busy marker (ActiveAsyncJobId) is only
        cleared if it still names this job, so a newer job's marker is never wiped.
        Without it the marker is always cleared.
    .EXAMPLE
        Remove-ModuleContext -Context $ctx
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Context,
        [string]$JobId
    )

    if (-not $PSCmdlet.ShouldProcess($Context.Name, 'Discard module context')) { return }

    if (-not $JobId -or $Context.ActiveAsyncJobId -eq $JobId) { $Context.ActiveAsyncJobId = $null }
    try {
        if ($Context.Process -and -not $Context.Process.HasExited) {
            $Context.Process.Kill($true)
            $null = $Context.Process.WaitForExit(200)
        }
        if ($Context.Process -is [System.IDisposable]) { $Context.Process.Dispose() }
    } catch {
        Write-HubLog -Level Debug -Message "Failed to kill process for $($Context.Name) : $($_.Exception.Message)"
    }
    if ($Context.Runspace) {
        try { $Context.Runspace.CloseAsync() } catch {
            Write-HubLog -Level Debug -Message "Failed to close runspace for $($Context.Name) : $($_.Exception.Message)"
        }
    }
    if ($Context.CommsDir -and (Test-Path $Context.CommsDir)) {
        Remove-Item $Context.CommsDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($Context.Name -and $script:ModuleRunspaces -and $script:ModuleRunspaces.ContainsKey($Context.Name) -and
        [object]::ReferenceEquals($script:ModuleRunspaces[$Context.Name], $Context)) {
        $script:ModuleRunspaces.Remove($Context.Name)
    }
}

function Get-ModuleFileKey {
    <#
    .SYNOPSIS
        Returns a cache key for a module that changes when its manifest or script file is edited.
    .DESCRIPTION
        Built from the module name, path and the last-write ticks of the .psd1 and the
        matching .psm1, so a cached value is dropped naturally when either file changes.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .EXAMPLE
        $key = Get-ModuleFileKey -ModuleEntry $mod
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ModuleEntry)

    $psm1Path = $ModuleEntry.path -replace '\.psd1$', '.psm1'
    $psd1Ticks = if (Test-Path -LiteralPath $ModuleEntry.path) { (Get-Item -LiteralPath $ModuleEntry.path).LastWriteTimeUtc.Ticks } else { 0 }
    $psm1Ticks = if (Test-Path -LiteralPath $psm1Path) { (Get-Item -LiteralPath $psm1Path).LastWriteTimeUtc.Ticks } else { 0 }
    return "$($ModuleEntry.name)|$($ModuleEntry.path)|$psd1Ticks|$psm1Ticks"
}

function Get-RequiredIsolationMode {
    param([object]$ModuleEntry)

    # ── 1. Check for explicit override in modules.json ──
    # Set "isolation": "process" or "isolation": "runspace" per module. Checked before
    # the cache so changing it takes effect immediately.
    if ($ModuleEntry.PSObject.Properties.Name -contains 'isolation' -and $ModuleEntry.isolation) {
        $override = $ModuleEntry.isolation.ToLower()
        if ($override -in @('process', 'runspace')) {
            Write-HubLog -Level Debug -Message "Isolation override for $($ModuleEntry.name): $override"
            return $override
        }
    }

    # The scan reads the manifest, the .psm1 and up to 20 .ps1 files; cache it per
    # module, keyed on cheap stat calls so an edited module is rescanned.
    if (-not $script:IsolationModeCache) { $script:IsolationModeCache = @{} }
    $cacheKey = Get-ModuleFileKey -ModuleEntry $ModuleEntry
    if ($script:IsolationModeCache.ContainsKey($cacheKey)) { return $script:IsolationModeCache[$cacheKey] }

    $detected = Resolve-IsolationMode -ModuleEntry $ModuleEntry
    $script:IsolationModeCache[$cacheKey] = $detected
    return $detected
}

function Resolve-IsolationMode {
    param([object]$ModuleEntry)

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
    $importError = $null
    try {
        # The path is an argument, never script text — no quoting rules to get wrong.
        $ps.AddScript('param($p) Import-Module -Name $p -Force -DisableNameChecking -ErrorAction Stop').AddArgument($ModuleEntry.path) | Out-Null
        $null = $ps.Invoke()
        if ($ps.HadErrors) {
            $first = @($ps.Streams.Error)[0]
            $importError = if ($first) { $first.ToString() } else { 'unknown error' }
        }
    } catch {
        $importError = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
    } finally { $ps.Dispose() }

    if ($importError) {
        Write-HubLog -Level Error -Message "Failed to import $name : $importError"
        $runspace.Dispose()
        throw "Failed to import module '$name': $importError"
    }

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
    $scopeName = Get-ModuleScopeName -ModuleEntry $ModuleEntry

    # These values go onto a pwsh command line wrapped in double quotes. Spaces are fine inside
    # the quotes; a double quote would end the argument early, a backslash can escape the
    # closing quote, and control characters have no place in a module name.
    foreach ($check in @(@{ Label = 'module name'; Value = $name }, @{ Label = 'module scope name'; Value = $scopeName })) {
        if ([string]::IsNullOrWhiteSpace($check.Value) -or $check.Value -match '["\\\p{Cc}]') {
            throw "Invalid $($check.Label) '$($check.Value)': double quotes, backslashes and control characters are not allowed for process isolation."
        }
    }

    Write-HubLog -Level Info -Message "Creating PROCESS for: $name (full DLL isolation)"

    $commsDir = Join-Path $script:LogDir "process_$($name -replace '[^a-zA-Z0-9_-]','_')"
    if (Test-Path $commsDir) { Remove-Item $commsDir -Recurse -Force }
    New-Item $commsDir -ItemType Directory -Force | Out-Null

    # The channel carries commands and their output: limit it to the current user and SYSTEM.
    try {
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $none = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        $full = [System.Security.AccessControl.FileSystemRights]::FullControl
        $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        foreach ($sid in @($userSid, $systemSid)) {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, $full, $inherit, $none, $allow))
        }
        Set-Acl -LiteralPath $commsDir -AclObject $acl
    } catch {
        Write-HubLog -Level Warning -Message "Could not restrict access to $commsDir : $($_.Exception.Message)"
    }

    $commandFile  = Join-Path $commsDir 'command.json'
    $responseFile = Join-Path $commsDir 'response.json'
    $readyFile    = Join-Path $commsDir 'ready'
    $exitFile     = Join-Path $commsDir 'exit'

    # SECURITY: The worker is a fixed file shipped with the module (Workers/ProcessWorker.ps1),
    # not generated text written per module then launched with -ExecutionPolicy Bypass. The
    # per-module values are passed as parameters — the module folder is a much narrower,
    # install-time-controlled write surface than the comms directory under Logs.
    $workerPath = Join-Path $script:NexusRoot 'Workers' 'ProcessWorker.ps1'
    if (-not (Test-Path $workerPath)) {
        Write-HubLog -Level Error -Message "Process worker script missing: $workerPath"
        return $null
    }

    # Start-Process joins -ArgumentList entries with spaces without quoting them, so a
    # path containing a space (a OneDrive folder, "Program Files") is split into separate
    # arguments and pwsh exits immediately with "is not recognized as the name of a script
    # file". Every path value is quoted here — Windows paths cannot contain a double quote,
    # so wrapping is enough.
    $pwshPath = (Get-Process -Id $PID).Path
    $proc = Start-Process -FilePath $pwshPath `
        -ArgumentList @(
            '-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$workerPath`"",
            '-ModulePath', "`"$($ModuleEntry.path)`"",
            '-ModuleName', "`"$name`"",
            '-ModuleScope', "`"$scopeName`"",
            '-ParentPid', "$PID",
            '-CommsDir', "`"$commsDir`""
        ) `
        -WindowStyle Minimized `
        -PassThru

    Write-HubLog -Level Info -Message "Process started: $name (PID $($proc.Id))"

    $ready = $false
    $timeout = [DateTime]::Now.AddSeconds(60)
    while ([DateTime]::Now -lt $timeout) {
        if ($proc.HasExited) {
            Write-HubLog -Level Error -Message "Process for $name exited prematurely"
            return $null
        }
        if (Test-Path $readyFile) {
            $readyContent = (Get-Content $readyFile -Raw).Trim()
            Remove-Item $readyFile -Force -ErrorAction SilentlyContinue
            if ($readyContent -eq 'ready') { $ready = $true; break }
            else {
                Write-HubLog -Level Error -Message "Process import failed for $name : $readyContent"
                try { $proc.Kill($true) } catch { Write-HubLog -Level Debug -Message "Failed to terminate process for $name : $($_.Exception.Message)" }
                return $null
            }
        }
        Start-Sleep -Milliseconds 300
    }

    # Without this a worker still importing after 60 s was registered as ready anyway.
    if (-not $ready) {
        Write-HubLog -Level Error -Message "Process for $name did not become ready within 60 s"
        try { $proc.Kill($true) } catch { Write-HubLog -Level Debug -Message "Failed to terminate process for $name : $($_.Exception.Message)" }
        return $null
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
