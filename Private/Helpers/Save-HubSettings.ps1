function Save-HubSettings {
    <#
    .SYNOPSIS
        Writes the settings object to disk atomically.
    .DESCRIPTION
        Serialises through Write-AtomicFile (temp file in the same folder, then rename),
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

    try {
        Write-AtomicFile -Path $script:SettingsFile -Value $json
    } catch {
        Write-HubLog -Level Error -Message "Failed to save settings: $($_.Exception.Message)"
        throw
    }
}
