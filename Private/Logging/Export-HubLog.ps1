function Export-HubLog {
    <#
    .SYNOPSIS
        Exports the current session log or a daily log file.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath,
        [switch]$SessionOnly
    )

    if ($SessionOnly) {
        $data = $script:HubLogSession
    } else {
        $logFile = Join-Path $script:LogDir "Nexus_$(Get-Date -Format 'yyyyMMdd').log"
        if (Test-Path $logFile) {
            $data = Get-Content $logFile -Raw
        } else {
            Write-HubLog -Level Warning -Message 'No log file found for today'
            return
        }
    }

    if ($OutputPath) {
        if ($SessionOnly) {
            $data | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding utf8
        } else {
            $data | Out-File -FilePath $OutputPath -Encoding utf8
        }
        Write-HubLog -Level Info -Message "Log exported to $OutputPath"
    } else {
        return $data
    }
}
