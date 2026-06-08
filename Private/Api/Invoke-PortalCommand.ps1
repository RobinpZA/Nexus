function Invoke-PortalCommand {
    <#
    .SYNOPSIS
        API handler: POST /api/execute
        All commands run inside a persistent, isolated runspace per module.
        - Connect-* / Disconnect-*: SYNC (blocks, but auth dialogs can appear in the runspace)
        - Everything else: ASYNC (non-blocking, portal polls for result)

        Each module gets its own runspace, so:
        - Module A's Graph connection does not interfere with Module B's
        - Different DLL versions don't conflict
        - Auth tokens persist between commands within the same module
    #>
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $reader = [System.IO.StreamReader]::new($Context.Request.InputStream)
    $bodyRaw = $reader.ReadToEnd(); $reader.Close()

    try { $body = $bodyRaw | ConvertFrom-Json }
    catch { Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Invalid JSON body'; return }

    $moduleName  = $body.module
    $commandName = $body.command
    $parameters  = @{}

    if ($body.parameters) {
        $body.parameters.PSObject.Properties | ForEach-Object { $parameters[$_.Name] = $_.Value }
    }

    if (-not $moduleName -or -not $commandName) {
        Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Missing required fields: module, command'
        return
    }

    # Look up module
    $registry = Read-ModuleRegistry
    $mod = $registry.modules | Where-Object { $_.name -eq $moduleName }

    if (-not $mod) { Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Module not found: $moduleName"; return }
    if (-not $mod.enabled) { Write-ErrorResponse -Context $Context -StatusCode 403 -Message "Module is disabled: $moduleName"; return }

    # SECURITY: Validate command is in the module's export list
    $allowedCommands = @()
    if (Test-Path $mod.path) {
        try {
            $manifestData = Import-PowerShellDataFile -Path $mod.path -ErrorAction SilentlyContinue
            if ($manifestData) {
                if ($manifestData.FunctionsToExport) { $allowedCommands += @($manifestData.FunctionsToExport | Where-Object { $_ -and $_ -ne '*' }) }
                if ($manifestData.CmdletsToExport) { $allowedCommands += @($manifestData.CmdletsToExport | Where-Object { $_ -and $_ -ne '*' }) }
            }
        } catch {
            try {
                $manifest = Test-ModuleManifest -Path $mod.path -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                if ($manifest) { $allowedCommands += @($manifest.ExportedFunctions.Keys); $allowedCommands += @($manifest.ExportedCmdlets.Keys) }
            } catch {
                Write-HubLog -Level Debug -Message "Failed to read module exports for $moduleName : $($_.Exception.Message)"
            }
        }
    }

    if ($allowedCommands.Count -gt 0 -and $commandName -notin $allowedCommands) {
        Write-HubLog -Level Error -Message "BLOCKED: '$commandName' is not exported by '$moduleName'" -Source 'Security'
        Write-ErrorResponse -Context $Context -StatusCode 403 -Message "Command '$commandName' is not exported by module '$moduleName'"
        return
    }

    $trackRecent = {
        param($Success)

        try {
            $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            $recent = @{
                module    = $moduleName
                command   = $commandName
                timestamp = (Get-Date).ToUniversalTime().ToString('o')
                success   = $Success
            }
            $existingRecent = @($settings.recentCommands)
            $settings.recentCommands = @(@($recent) + $existingRecent | Select-Object -First $settings.maxRecentCommands)
            $settings | ConvertTo-Json -Depth 10 | Out-File $script:SettingsFile -Encoding utf8 -Force
        } catch {
            Write-HubLog -Level Debug -Message "Failed to update recent commands: $($_.Exception.Message)"
        }
    }

    # ── Determine execution mode ──
    $verb = $null
    if ($commandName -match '^([A-Za-z]+)-') { $verb = $Matches[1] }
    $connectionVerbs = @('Connect', 'Disconnect', 'Login', 'Logout')
    $isConnectionCommand = $verb -in $connectionVerbs

    if ($isConnectionCommand) {
        # ── SYNC in isolated runspace (blocks listener, but auth needs it) ──
        Write-HubLog -Level Info -Message "Running sync in runspace (connection): $commandName" -Source $moduleName

        $result = Invoke-InRunspace -ModuleEntry $mod -CommandName $commandName -Parameters $parameters
        & $trackRecent $result.success

        Write-JsonResponse -Context $Context -Data @{
            mode       = 'sync'
            success    = $result.success
            module     = $result.module
            command    = $result.command
            durationMs = $result.durationMs
            output     = @($result.output)
        }
    } else {
        # ── ASYNC in isolated runspace (non-blocking) ──
        Write-HubLog -Level Info -Message "Running async in runspace: $commandName" -Source $moduleName

        $jobId = Invoke-InRunspace -ModuleEntry $mod -CommandName $commandName -Parameters $parameters -Async

        if ($jobId -is [string]) {
            & $trackRecent $null
            Write-JsonResponse -Context $Context -Data @{
                mode    = 'async'
                jobId   = $jobId
                status  = 'running'
                module  = $moduleName
                command = $commandName
            }
        } else {
            # Invoke-InRunspace returned a result object (error case)
            & $trackRecent $jobId.success
            Write-JsonResponse -Context $Context -Data @{
                mode       = 'sync'
                success    = $jobId.success
                module     = $jobId.module
                command    = $jobId.command
                durationMs = $jobId.durationMs
                output     = @($jobId.output)
            }
        }
    }
}
