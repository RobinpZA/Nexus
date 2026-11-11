function Get-ListenerPortParameter {
    <#
    .SYNOPSIS
        Builds the ordered list of Start-HttpListener parameter sets Start-Nexus should try.
    .DESCRIPTION
        An explicit -Port is the only candidate. Otherwise defaultPort (when set and greater
        than 0) is tried first, followed by a scan of portRange. Each returned hashtable can be
        splatted into Start-HttpListener.
    .PARAMETER Port
        Explicit port requested by the caller; 0 or omitted means none.
    .PARAMETER Settings
        The settings object from Read-HubSettings (uses defaultPort and portRange).
    .EXAMPLE
        foreach ($p in Get-ListenerPortParameter -Settings (Read-HubSettings)) { Start-HttpListener @p }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [int]$Port,
        [Parameter(Mandatory)][object]$Settings
    )

    if ($Port) {
        return @(, @{ Port = $Port })
    }

    $candidates = [System.Collections.Generic.List[hashtable]]::new()

    $defaultPort = 0
    if ($null -ne $Settings.defaultPort) { $null = [int]::TryParse([string]$Settings.defaultPort, [ref]$defaultPort) }
    if ($defaultPort -gt 0 -and $defaultPort -le 65535) {
        $candidates.Add(@{ Port = $defaultPort })
    }

    $range = @($Settings.portRange)
    if ($range.Count -ge 2) {
        $candidates.Add(@{ PortRangeStart = [int]$range[0]; PortRangeEnd = [int]$range[1] })
    } elseif ($candidates.Count -eq 0) {
        $candidates.Add(@{ PortRangeStart = 8090; PortRangeEnd = 8099 })
    }

    return $candidates.ToArray()
}
