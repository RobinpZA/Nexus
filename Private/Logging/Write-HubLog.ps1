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

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Source    = $Source
        Message   = $Message
    }

    # Add to session log
    $script:HubLogSession += $entry

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
