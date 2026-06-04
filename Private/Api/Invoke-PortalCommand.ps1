function Invoke-PortalCommand {
    <#
    .SYNOPSIS
        API handler: POST /api/execute — imports module and runs a command.
        SECURITY: Command allowlist is enforced by Invoke-RegisteredCommand.
        Error details are sanitised before returning to client.
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

    if (-not $mod) {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Module not found: $moduleName"
        return
    }
    if (-not $mod.enabled) {
        Write-ErrorResponse -Context $Context -StatusCode 403 -Message "Module is disabled: $moduleName"
        return
    }

    # Execute (command allowlist enforced inside Invoke-RegisteredCommand)
    $result = Invoke-RegisteredCommand -ModuleEntry $mod -CommandName $commandName -Parameters $parameters

    # Track in recent commands
    try {
        $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
        $recent = @{ module = $moduleName; command = $commandName; timestamp = (Get-Date).ToUniversalTime().ToString('o'); success = $result.success }
        $existingRecent = @($settings.recentCommands)
        $settings.recentCommands = @(@($recent) + $existingRecent | Select-Object -First $settings.maxRecentCommands)
        $settings | ConvertTo-Json -Depth 10 | Out-File $script:SettingsFile -Encoding utf8 -Force
    } catch {
        Write-HubLog -Level Warning -Message "Failed to update recent commands: $($_.Exception.Message)"
    }

    Write-JsonResponse -Context $Context -Data @{
        success    = $result.success
        module     = $result.module
        command    = $result.command
        durationMs = $result.durationMs
        output     = @($result.output)
    }
}
