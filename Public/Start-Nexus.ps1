function Start-Nexus {
    <#
    .SYNOPSIS
        Launches the Nexus web portal. Starts an HTTP listener and opens the browser.
    .DESCRIPTION
        Starts a local HTTP server serving the Nexus portal. Optionally scans for modules on startup.
        Press Ctrl+C or use the portal's close button to stop.
    .PARAMETER Port
        Specific port to bind to. If not specified, tries ports in the configured range (default 8090-8099).
    .PARAMETER NoBrowser
        Do not auto-open the browser.
    .PARAMETER Scan
        Run a module folder scan on startup.
    .EXAMPLE
        Start-Nexus
    .EXAMPLE
        Start-Nexus -Port 9090 -NoBrowser
    .EXAMPLE
        Start-Nexus -Scan
    #>
    [CmdletBinding()]
    param(
        [int]$Port,
        [switch]$NoBrowser,
        [switch]$Scan
    )

    $bannerVersion = if ($script:NexusVersion) { [string]$script:NexusVersion } else { 'unknown' }
    $bannerTitle = "Nexus v$bannerVersion"

    Write-Host ''
    Write-Host '  ┌─────────────────────────────────────────┐' -ForegroundColor DarkCyan
    Write-Host ("  │ {0,-39} │" -f $bannerTitle) -ForegroundColor DarkCyan
    Write-Host '  │   Central PowerShell Module Hub         │' -ForegroundColor DarkCyan
    Write-Host '  └─────────────────────────────────────────┘' -ForegroundColor DarkCyan
    Write-Host ''

    # Load settings
    $settings = Read-HubSettings
    if ($settings.logLevel) { $script:LogLevel = [string]$settings.logLevel }
    $retention = if ($null -ne $settings.logRetentionDays) { [int]$settings.logRetentionDays } else { 30 }
    Remove-OldLog -RetentionDays $retention

    # Optional scan on startup
    if ($Scan -or $settings.scanOnStartup) {
        Write-HubLog -Level Info -Message 'Running module scan on startup...'
        $scanRoots = @($settings.scanRoots)
        if ($scanRoots.Count -gt 0) {
            $discovered = Invoke-ModuleScan -ScanRoots $scanRoots -MaxDepth $settings.scanDepth -Exclude @($settings.scanExclude)
            $null = Sync-ModuleRegistry -Discovered $discovered
        }
    }

    # Auto-import modules marked with autoImport
    $registry = Read-ModuleRegistry
    foreach ($mod in ($registry.modules | Where-Object { $_.autoImport -and $_.enabled })) {
        $null = Import-RegisteredModule -ModuleEntry $mod
    }

    # Start HTTP listener
    $listenerParams = @{}
    if ($Port) {
        $listenerParams['Port'] = $Port
    } else {
        $listenerParams['PortRangeStart'] = $settings.portRange[0]
        $listenerParams['PortRangeEnd']   = $settings.portRange[1]
    }

    $script:SessionToken = New-SessionToken
    $server = Start-HttpListener @listenerParams

    # Open-Nexus reads this to reopen the portal later. It lives under the per-user data
    # root (%LOCALAPPDATA% by default), which other users cannot read.
    $sessionFile = Join-Path $script:DataRoot 'session.json'
    @{
        url        = $server.Url
        token      = $script:SessionToken
        pid        = $PID
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -Path $sessionFile -Encoding utf8

    # Open browser
    if (-not $NoBrowser -and $settings.openBrowserOnStart) {
        Start-Sleep -Milliseconds 500
        try {
            Start-Process "$($server.Url)?token=$($script:SessionToken)"
        } catch {
            Write-HubLog -Level Warning -Message 'Could not open browser. Run Open-Nexus to open the portal.'
        }
    }

    # Blocking request loop
    try {
        while ($server.Listener.IsListening -and -not $script:StopListener) {
            try {
                $context = $server.Listener.GetContext()
                Invoke-RequestRouter -Context $context
            } catch [System.Net.HttpListenerException] {
                if ($script:StopListener) { break }
                Write-HubLog -Level Warning -Message "Listener exception: $($_.Exception.Message)"
            }
        }
    } finally {
        Write-HubLog -Level Info -Message 'Nexus shutting down...'
        if ($server.Listener.IsListening) {
            $server.Listener.Stop()
        }
        $server.Listener.Dispose()
        $script:Listener = $null
        $script:SessionToken = $null
        Remove-Item -Path $sessionFile -Force -ErrorAction SilentlyContinue
        # Close module runspaces and child processes — otherwise every session leaves
        # a pwsh worker per process-isolated module running.
        Stop-ModuleContext
        Write-Host ''
        Write-Host '  Nexus stopped.' -ForegroundColor DarkCyan
        Write-Host ''
    }
}
