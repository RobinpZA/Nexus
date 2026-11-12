function Stop-Nexus {
    <#
    .SYNOPSIS
        Gracefully stops the Nexus web portal.
    .DESCRIPTION
        Stops the listener running in the current process when there is one. Otherwise
        reads session.json from the data root and asks the running instance (for example
        an autostarted one in a hidden pwsh) to shut down through POST /api/shutdown.
        If that request fails and the recorded process is still a pwsh/powershell
        process, that process is stopped.
    .EXAMPLE
        Stop-Nexus
    .EXAMPLE
        Stop-Nexus -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($script:Listener -and $script:Listener.IsListening) {
        if (-not $PSCmdlet.ShouldProcess('Nexus listener (this process)', 'Stop')) { return }
        $script:StopListener = $true
        Write-HubLog -Level Info -Message 'Stop signal sent to Nexus listener'
        $script:Listener.Stop()
        return
    }

    $sessionFile = Join-Path $script:DataRoot 'session.json'
    $session = $null
    if (Test-Path -Path $sessionFile) {
        try { $session = Get-Content -Path $sessionFile -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop } catch { $session = $null }
    }
    if (-not $session -or -not $session.url) {
        Write-HubLog -Level Warning -Message 'No running Nexus instance found'
        return
    }

    if (-not $PSCmdlet.ShouldProcess("Nexus instance at $($session.url) (PID $($session.pid))", 'Stop')) { return }

    $base = ([string]$session.url).TrimEnd('/')
    try {
        $null = Invoke-RestMethod -Uri "$base/api/shutdown" -Method Post -Body '{}' `
            -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop `
            -Headers @{ 'X-Nexus-Token' = [string]$session.token; 'Origin' = $base }
        Write-HubLog -Level Info -Message "Shutdown requested for Nexus at $base"
        return
    } catch {
        Write-HubLog -Level Warning -Message "Shutdown request failed: $($_.Exception.Message)"
    }

    $proc = if ($session.pid) { Get-Process -Id ([int]$session.pid) -ErrorAction SilentlyContinue } else { $null }
    # Guard against PID reuse: only a pwsh that started shortly before the session was written is ours.
    $isOurs = $false
    if ($proc -and $proc.ProcessName -in @('pwsh', 'powershell') -and $session.startedUtc) {
        try {
            $sessionStart = ([datetime]$session.startedUtc).ToUniversalTime()
            $gap = ($sessionStart - $proc.StartTime.ToUniversalTime()).TotalSeconds
            $isOurs = $gap -ge 0 -and $gap -le 300
        } catch {
            Write-HubLog -Level Debug -Message "Could not verify process start time: $($_.Exception.Message)"
        }
    }
    if ($proc -and -not $isOurs) {
        Write-HubLog -Level Warning -Message "PID $($session.pid) does not look like the Nexus that wrote session.json; not stopping it. Removing the stale session file."
        Remove-Item -Path $sessionFile -Force -ErrorAction SilentlyContinue
    } elseif ($isOurs) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $sessionFile -Force -ErrorAction SilentlyContinue
        Write-HubLog -Level Info -Message "Stopped Nexus process $($proc.Id)"
    } else {
        Write-HubLog -Level Warning -Message 'No running Nexus instance found'
    }
}
