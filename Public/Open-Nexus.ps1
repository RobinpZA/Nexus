function Open-Nexus {
    <#
    .SYNOPSIS
        Opens the running Nexus portal in the browser with a valid session.
    .DESCRIPTION
        The portal API requires a per-session token, which Start-Nexus writes to
        session.json under the Nexus data root. Use this after starting Nexus with
        -NoBrowser (for example from Enable-NexusAutoStart), or after closing the tab.
    .PARAMETER PassThru
        Return the session URL instead of opening the browser.
    .EXAMPLE
        Open-Nexus
    .EXAMPLE
        $url = Open-Nexus -PassThru
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$PassThru)

    $sessionFile = Join-Path $script:DataRoot 'session.json'
    if (-not (Test-Path $sessionFile)) {
        throw 'Nexus is not running. Start it with Start-Nexus.'
    }

    $session = Get-Content -Path $sessionFile -Raw | ConvertFrom-Json
    if (-not (Get-Process -Id $session.pid -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $sessionFile -Force -ErrorAction SilentlyContinue
        throw 'Nexus is not running (stale session file removed). Start it with Start-Nexus.'
    }

    $url = "$($session.url)?token=$($session.token)"
    if ($PassThru) { return $url }
    Start-Process $url
}
