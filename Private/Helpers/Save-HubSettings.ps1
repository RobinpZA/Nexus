function Save-HubSettings {
    <#
    .SYNOPSIS
        Writes the settings object to disk atomically.
    .DESCRIPTION
        Serialises to a temporary file in the same folder and then replaces the target,
        so an interrupted write cannot leave a truncated settings.json behind.
    .PARAMETER Settings
        The full settings object to persist.
    .EXAMPLE
        Save-HubSettings -Settings $settings
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Settings
    )

    if (-not $PSCmdlet.ShouldProcess($script:SettingsFile, 'Write settings')) { return }

    $json = $Settings | ConvertTo-Json -Depth 10
    $temp = "$($script:SettingsFile).tmp"

    try {
        Set-Content -Path $temp -Value $json -Encoding utf8 -Force -ErrorAction Stop
        Move-Item -Path $temp -Destination $script:SettingsFile -Force -ErrorAction Stop
    } catch {
        if (Test-Path $temp) { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
        Write-HubLog -Level Error -Message "Failed to save settings: $($_.Exception.Message)"
        throw
    }
}
