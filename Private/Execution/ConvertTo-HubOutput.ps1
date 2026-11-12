function ConvertTo-HubOutput {
    <#
    .SYNOPSIS
        Converts raw PowerShell records into the portal's { stream, message, data } output shape.
    .DESCRIPTION
        Commands run with *>&1, so error and warning records arrive on the success stream.
        Classifying by record type is the only way to tell them apart — checking
        $PowerShell.Streams.Error after a merge always reports zero errors.

        Success-stream objects also carry `data`: a flat property bag the portal renders
        as a table and exports to CSV. `message` stays as the one-line text form.

        Workers/ProcessWorker.ps1 dot-sources this file, so keep it free of other Nexus
        functions.
    .PARAMETER Records
        The records returned by Invoke()/EndInvoke() or read from a stream collection.
    .PARAMETER MaxRows
        Cap on the number of non-error records kept. 0 (the default) means no cap. Error
        records are exempt from this cap so a failure is never hidden by it, but have their
        own cap of 100 (the function cannot read settings): beyond that a single Warning
        record says errors were suppressed, and the rest are counted in Total but dropped.
        Every record's message is truncated to 4000 characters.
    .PARAMETER Summary
        A hashtable that receives (and accumulates across calls) Total, Kept and Truncated.
        Pass the same hashtable on every call when records are shaped one at a time.
        Total counts every record seen, before capping. Errors and ErrorsSuppressed track
        the error cap.
    .EXAMPLE
        $output = @(ConvertTo-HubOutput -Records $ps.Invoke())
    .EXAMPLE
        $summary = @{}; $output = @(ConvertTo-HubOutput -Records $records -MaxRows 1000 -Summary $summary)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object[]]$Records,

        [int]$MaxRows = 0,

        [hashtable]$Summary
    )

    if ($null -eq $Summary) { $Summary = @{} }
    if (-not $Summary.ContainsKey('Total')) { $Summary['Total'] = 0 }
    if (-not $Summary.ContainsKey('Kept')) { $Summary['Kept'] = 0 }
    if (-not $Summary.ContainsKey('Truncated')) { $Summary['Truncated'] = $false }
    if (-not $Summary.ContainsKey('Errors')) { $Summary['Errors'] = 0 }
    if (-not $Summary.ContainsKey('ErrorsSuppressed')) { $Summary['ErrorsSuppressed'] = 0 }
    $maxErrors = 100
    $maxMessageLength = 4000

    $output = [System.Collections.Generic.List[PSCustomObject]]::new()
    # A lone 0, $false or '' binds as a one-element array that is itself falsy.
    if ($null -eq $Records -or @($Records).Count -eq 0) { return $output }

    # Errors in this call beyond the cap; only known when records arrive in a batch.
    $batchErrors = @($Records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count
    $overCap = $batchErrors - [math]::Max(0, $maxErrors - $Summary['Errors'])

    foreach ($item in $Records) {
        if ($null -eq $item) { continue }
        $Summary['Total'] = $Summary['Total'] + 1
        $isError = $item -is [System.Management.Automation.ErrorRecord]
        if ($isError) {
            $Summary['Errors'] = $Summary['Errors'] + 1
            if ($Summary['Errors'] -gt $maxErrors) {
                $Summary['ErrorsSuppressed'] = $Summary['ErrorsSuppressed'] + 1
                $Summary['Truncated'] = $true
                if ($Summary['ErrorsSuppressed'] -eq 1) {
                    $note = if ($overCap -gt 1) { "$overCap more errors suppressed" } else { "More errors suppressed (first $maxErrors shown)" }
                    $output.Add([PSCustomObject]@{ stream = 'Warning'; message = $note })
                }
                continue
            }
        }
        if ($MaxRows -gt 0 -and -not $isError -and $Summary['Kept'] -ge $MaxRows) {
            $Summary['Truncated'] = $true
            continue
        }
        if (-not $isError) { $Summary['Kept'] = $Summary['Kept'] + 1 }
        $stream = switch ($item.GetType().Name) {
            'ErrorRecord'       { 'Error' }
            'WarningRecord'     { 'Warning' }
            'InformationRecord' { 'Information' }
            'VerboseRecord'     { 'Verbose' }
            'DebugRecord'       { 'Debug' }
            default             { 'Success' }
        }
        $entry = [PSCustomObject]@{ stream = $stream; message = $item.ToString() }
        if ($stream -eq 'Success') {
            $data = ConvertTo-HubOutputData -InputObject $item
            if ($data) {
                $entry | Add-Member -NotePropertyName data -NotePropertyValue $data
                # PSCustomObject.ToString() is empty — keep a readable line for Copy and CLI clients.
                if ([string]::IsNullOrWhiteSpace($entry.message)) {
                    $entry.message = ($data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
                }
            }
        }
        if ($entry.message.Length -gt $maxMessageLength) {
            $entry.message = $entry.message.Substring(0, $maxMessageLength) + '... (truncated)'
        }
        $output.Add($entry)
    }

    return $output
}

function ConvertTo-HubOutputData {
    <#
    .SYNOPSIS
        Flattens one output object into an ordered name -> scalar map, or $null for scalars.
    .DESCRIPTION
        Uses the type's default display properties when it declares them (what
        Format-Table would show), otherwise its data properties, capped at 30 columns.
        Script properties are skipped unless the type lists them for display: they run
        code on read and can be slow or throw. Every value is reduced to a string,
        number or boolean so the result serialises flat at any JSON depth.
    .PARAMETER InputObject
        One success-stream object.
    .EXAMPLE
        ConvertTo-HubOutputData -InputObject (Get-Item .)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$InputObject)

    $base = if ($InputObject -is [psobject]) { $InputObject.PSObject.BaseObject } else { $InputObject }
    if ($base -is [string] -or $base -is [ValueType]) { return $null }

    $data = [ordered]@{}

    if ($base -is [System.Collections.IDictionary]) {
        foreach ($key in @($base.Keys | Select-Object -First 30)) {
            $data["$key"] = ConvertTo-HubCellValue -Value $base[$key]
        }
        return $data
    }

    $names = $null
    try { $names = $InputObject.PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames } catch { $names = $null }
    if (-not $names) {
        $names = @($InputObject.PSObject.Properties |
            Where-Object { $_.MemberType -in @('Property', 'NoteProperty', 'AliasProperty') } |
            Select-Object -First 30 -ExpandProperty Name)
    }
    if (-not $names) { return $null }

    foreach ($name in $names) {
        $value = try { $InputObject.$name } catch { '(unreadable)' }
        $data[$name] = ConvertTo-HubCellValue -Value $value
    }
    return $data
}

function ConvertTo-HubCellValue {
    <#
    .SYNOPSIS
        Reduces a property value to a string, number, boolean or $null for a table cell.
    .PARAMETER Value
        The property value.
    .EXAMPLE
        ConvertTo-HubCellValue -Value (Get-Date)
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [psobject]) { $Value = $Value.PSObject.BaseObject }

    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    if ($Value -is [datetimeoffset]) { return $Value.ToString('o') }

    $text = if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        (@($Value | Select-Object -First 20) | ForEach-Object { "$_" }) -join '; '
    } else {
        "$Value"
    }
    if ($text.Length -gt 1000) { $text = $text.Substring(0, 1000) + '…' }
    return $text
}
