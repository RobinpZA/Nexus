function ConvertTo-HubOutput {
    <#
    .SYNOPSIS
        Converts raw PowerShell records into the portal's { stream, message } output shape.
    .DESCRIPTION
        Commands run with *>&1, so error and warning records arrive on the success stream.
        Classifying by record type is the only way to tell them apart — checking
        $PowerShell.Streams.Error after a merge always reports zero errors.
    .PARAMETER Records
        The records returned by Invoke()/EndInvoke() or read from a stream collection.
    .EXAMPLE
        $output = @(ConvertTo-HubOutput -Records $ps.Invoke())
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object[]]$Records
    )

    $output = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $Records) { return $output }

    foreach ($item in $Records) {
        if ($null -eq $item) { continue }
        $stream = switch ($item.GetType().Name) {
            'ErrorRecord'       { 'Error' }
            'WarningRecord'     { 'Warning' }
            'InformationRecord' { 'Information' }
            'VerboseRecord'     { 'Verbose' }
            'DebugRecord'       { 'Debug' }
            default             { 'Success' }
        }
        $output.Add([PSCustomObject]@{ stream = $stream; message = $item.ToString() })
    }

    return $output
}
