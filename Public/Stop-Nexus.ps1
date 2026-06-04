function Stop-Nexus {
    <#
    .SYNOPSIS
        Gracefully stops the Nexus web portal.
    .EXAMPLE
        Stop-Nexus
    #>
    [CmdletBinding()]
    param()

    $script:StopListener = $true

    if ($script:Listener -and $script:Listener.IsListening) {
        Write-HubLog -Level Info -Message 'Stop signal sent to Nexus listener'
        $script:Listener.Stop()
    } else {
        Write-HubLog -Level Warning -Message 'No active Nexus listener found'
    }
}
