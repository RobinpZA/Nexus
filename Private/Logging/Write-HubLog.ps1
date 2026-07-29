function Write-HubLog {
    <#
    .SYNOPSIS
        Writes a structured log entry to the console and session log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Source = 'Nexus'
    )

    # Honour the configured logLevel — Debug entries are noise outside troubleshooting.
    $rank = @{ Debug = 0; Info = 1; Warning = 2; Error = 3 }
    $threshold = if ($script:LogLevel -and $rank.ContainsKey($script:LogLevel)) { $rank[$script:LogLevel] } else { 1 }
    if ($rank[$Level] -lt $threshold) { return }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Source    = $Source
        Message   = $Message
    }

    # Add to session log, capped so a long-running server does not grow without bound.
    if ($null -eq $script:HubLogSession) { $script:HubLogSession = [System.Collections.Generic.List[PSCustomObject]]::new() }
    $script:HubLogSession.Add($entry)
    if ($script:HubLogSession.Count -gt 2000) { $script:HubLogSession.RemoveRange(0, 500) }

    # Console output with colour
    $colour = switch ($Level) {
        'Debug'   { 'DarkGray' }
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colour

    # Append to daily log file
    $logFile = Join-Path $script:LogDir "Nexus_$(Get-Date -Format 'yyyyMMdd').log"
    "$timestamp`t$Level`t$Source`t$Message" | Out-File -FilePath $logFile -Append -Encoding utf8
}
