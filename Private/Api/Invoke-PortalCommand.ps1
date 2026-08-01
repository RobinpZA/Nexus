function Invoke-PortalCommand {
    <#
    .SYNOPSIS
        API handler: POST /api/execute
        All commands run inside a persistent, isolated context per module — a runspace, or
        a child process for modules that load Graph/EXO/Teams. Every command, including
        Connect/Disconnect, returns a job id and is polled — see Invoke-InRunspace for why
        connection commands don't need to be synchronous.

        What the isolation does cover:
        - Different DLL versions do not conflict between modules
        - In-memory session state stays within one module's context
        - A module's context keeps its session between commands

        What it does NOT cover: credential caches that live on disk. Microsoft Graph
        persists delegated tokens under the user's profile unless a module connects with
        -ContextScope Process, so a sign-in made in one module can be reused silently by
        another — and by any other process running as that user. The portal reports this
        per module via /api/modules/{name}/connection.
    #>
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $body = Read-JsonRequestBody -Context $Context
    if ($null -eq $body) { Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Invalid JSON body'; return }

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

    # Fast-path rejection when the manifest declares an explicit export list — lets a
    # disallowed command 403 immediately instead of spinning up a runspace/process.
    # NOT the security boundary: a manifest can declare `FunctionsToExport = '*'`, which
    # leaves $allowedCommands empty and this check inert. The authoritative check is
    # inside the module's own runspace/process (Get-RunspaceInvokeScript / worker.ps1),
    # which resolves the command scoped to the module (-Module $moduleName) regardless
    # of what the manifest claims.
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
        param($Success, $JobId)

        try {
            $settings = Read-HubSettings
            $recent = @{
                module    = $moduleName
                command   = $commandName
                timestamp = (Get-Date).ToUniversalTime().ToString('o')
                success   = $Success
                jobId     = $JobId
            }
            $existingRecent = @($settings.recentCommands)
            $settings.recentCommands = @(@($recent) + $existingRecent | Select-Object -First $settings.maxRecentCommands)
            Save-HubSettings -Settings $settings
        } catch {
            Write-HubLog -Level Debug -Message "Failed to update recent commands: $($_.Exception.Message)"
        }
    }

    # ── Execute ──
    # Invoke-InRunspace decides sync vs async from the module's isolation mode: it
    # returns a job id when the command was started in the background, or a finished
    # result object when it ran synchronously or could not start.
    $outcome = Invoke-InRunspace -ModuleEntry $mod -CommandName $commandName -Parameters $parameters -Async

    if ($outcome -is [string]) {
        & $trackRecent $null $outcome
        Write-JsonResponse -Context $Context -Data @{
            mode    = 'async'
            jobId   = $outcome
            status  = 'running'
            module  = $moduleName
            command = $commandName
        }
    } else {
        & $trackRecent $outcome.success
        Write-JsonResponse -Context $Context -Data @{
            mode       = 'sync'
            success    = $outcome.success
            module     = $outcome.module
            command    = $outcome.command
            durationMs = $outcome.durationMs
            output     = @($outcome.output)
        }
    }
}
