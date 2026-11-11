function Get-MaxOutputRow {
    <#
    .SYNOPSIS
        Returns the configured cap on output records per command (maxOutputRows).
    .DESCRIPTION
        The cap is read on the listener thread and handed to the code that shapes output
        (ConvertTo-HubOutput runs inside runspaces and workers, which cannot read settings).
        An absent or out-of-range value falls back to the default of 1000.
    .EXAMPLE
        $maxRows = Get-MaxOutputRow
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $default = 1000
    try {
        $value = (Read-HubSettings).maxOutputRows
        $parsed = 0
        if ($null -ne $value -and [int]::TryParse("$value", [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 100000) {
            return $parsed
        }
    } catch {
        Write-HubLog -Level Debug -Message "Could not read maxOutputRows: $($_.Exception.Message)"
    }
    return $default
}
