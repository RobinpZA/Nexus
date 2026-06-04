function Test-ModulePath {
    <#
    .SYNOPSIS
        Validates that a module path exists and its manifest can be loaded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $result = [PSCustomObject]@{
        Path    = $Path
        Exists  = $false
        Valid   = $false
        Error   = $null
    }

    if (-not (Test-Path $Path)) {
        $result.Error = "Path does not exist: $Path"
        return $result
    }

    $result.Exists = $true

    try {
        $null = Test-ModuleManifest -Path $Path -ErrorAction Stop
        $result.Valid = $true
    } catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}
