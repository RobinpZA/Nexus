function ConvertTo-BoundParameter {
    <#
    .SYNOPSIS
        Converts portal-supplied parameter values into a splattable hashtable for a command.
    .DESCRIPTION
        The single binder for every execution path. It runs in three places: the Nexus
        session (Invoke-RegisteredCommand), module runspaces (Get-RunspaceInvokeScript
        dot-sources this file) and child processes (Workers/ProcessWorker.ps1 dot-sources
        it). Keep it free of other Nexus functions for that reason.

        The portal sends every text field as a string. PowerShell's binder already turns
        "5" into [int] or "2026-01-01" into [datetime], so those pass through. The cases it
        gets wrong are handled here:
          - [switch]/[bool]: "false" must be off — [bool]'false' is $true.
          - Arrays: "a, b" must become two elements, not one element "a, b".
          - Blank text: an empty field means "not supplied", not an empty string.

        SECURITY: Unknown parameter names throw instead of being passed through, so a
        request can only bind parameters the command declares.
    .PARAMETER Command
        The resolved CommandInfo the values will be splatted to.
    .PARAMETER Parameters
        Parameter names and raw values from the request.
    .EXAMPLE
        $bound = ConvertTo-BoundParameter -Command $cmd -Parameters @{ Top = '5'; Ids = 'a, b' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.CommandInfo]$Command,
        [AllowNull()][System.Collections.IDictionary]$Parameters
    )

    $bound = @{}
    if (-not $Parameters) { return $bound }

    foreach ($key in @($Parameters.Keys)) {
        $meta = $Command.Parameters[$key]
        if (-not $meta) { throw "Parameter '$key' is not valid for command '$($Command.Name)'." }

        $value = $Parameters[$key]
        $type  = $meta.ParameterType

        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { continue }

        if ($type -eq [switch] -or $type -eq [bool]) {
            $bound[$key] = ($value -is [bool] -and $value) -or ("$value".Trim().ToLowerInvariant() -in @('true', '1', 'yes', 'on'))
        } elseif ($type.IsArray -and $value -is [string]) {
            $bound[$key] = @($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } else {
            $bound[$key] = $value
        }
    }

    return $bound
}
