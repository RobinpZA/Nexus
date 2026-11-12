function Merge-HubSettings {
    <#
    .SYNOPSIS
        Merges a client-supplied settings payload into the current settings.
    .DESCRIPTION
        SECURITY / SAFETY: Only known keys are accepted and each is type- and range-checked,
        so a partial or malformed body cannot wipe scan roots, favourites or the port range.
        Unknown keys are ignored. favouriteCommands and recentCommands are owned by their own
        endpoints and are never taken from a settings payload.

        Throws on an invalid value so the caller can answer 400.
    .PARAMETER Current
        The settings object currently on disk.
    .PARAMETER Incoming
        The deserialised request body.
    .EXAMPLE
        $merged = Merge-HubSettings -Current (Read-HubSettings) -Incoming $body
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Current,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object]$Incoming
    )

    # A scalar, array or null body would otherwise surface as a binding/property error.
    if ($Incoming -isnot [System.Management.Automation.PSCustomObject] -and $Incoming -isnot [System.Collections.IDictionary]) {
        throw 'Settings body must be a JSON object.'
    }
    if ($Incoming -is [System.Collections.IDictionary]) { $Incoming = [PSCustomObject]$Incoming }

    $schema = [ordered]@{
        defaultPort          = 'port'
        portRange            = 'portRange'
        openBrowserOnStart   = 'bool'
        logLevel             = 'logLevel'
        logRetentionDays     = 'retention'
        scanOnStartup        = 'bool'
        allowUncScanRoots    = 'bool'
        scanRoots            = 'pathArray'
        scanDepth            = 'depth'
        scanExclude          = 'stringArray'
        scanPublishedModules = 'bool'
        publishedModulePaths = 'pathArray'
        theme                = 'theme'
        maxRecentCommands    = 'count'
        maxOutputRows        = 'rows'
    }

    # Deep clone so a validation failure part-way through leaves the caller's object untouched.
    $merged = $Current | ConvertTo-Json -Depth 10 | ConvertFrom-Json

    # Resolved up front so path validation sees the UNC setting from this same payload.
    $allowUnc = $false
    $uncProperty = $Incoming.PSObject.Properties['allowUncScanRoots']
    if ($uncProperty) { $allowUnc = ConvertTo-HubBoolean -Value $uncProperty.Value -Key 'allowUncScanRoots' }
    elseif ($Current.PSObject.Properties['allowUncScanRoots']) { $allowUnc = [bool]$Current.allowUncScanRoots }

    foreach ($key in $schema.Keys) {
        $property = $Incoming.PSObject.Properties[$key]
        if (-not $property) { continue }

        $value = $property.Value
        $coerced = switch ($schema[$key]) {
            'bool'        { ConvertTo-HubBoolean -Value $value -Key $key }
            'port'        { ConvertTo-HubInteger -Value $value -Key $key -Minimum 1 -Maximum 65535 }
            'retention'   { ConvertTo-HubInteger -Value $value -Key $key -Minimum 0 -Maximum 3650 }
            'depth'       { ConvertTo-HubInteger -Value $value -Key $key -Minimum 0 -Maximum 10 }
            'count'       { ConvertTo-HubInteger -Value $value -Key $key -Minimum 1 -Maximum 1000 }
            'rows'        { ConvertTo-HubInteger -Value $value -Key $key -Minimum 1 -Maximum 100000 }
            'stringArray' { @(@($value) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
            'pathArray'   {
                $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $paths = [System.Collections.Generic.List[string]]::new()
                foreach ($item in @($value)) {
                    if ($null -eq $item) { continue }
                    $check = Test-ScanRootPath -Path ([string]$item) -AllowUnc:$allowUnc
                    if (-not $check.Valid) { throw "Invalid path for '$key': $($check.Reason)" }
                    if ($seen.Add($check.Path)) { $paths.Add($check.Path) }
                }
                , @($paths)
            }
            'logLevel'    {
                if ([string]$value -notin @('Debug', 'Info', 'Warning', 'Error')) {
                    throw "Invalid value for 'logLevel': must be Debug, Info, Warning or Error."
                }
                [string]$value
            }
            'theme' {
                $theme = [string]$value
                if ($theme.Length -eq 0 -or $theme.Length -gt 32) { throw "Invalid value for 'theme'." }
                $theme
            }
            'portRange' {
                $range = @($value)
                if ($range.Count -ne 2) { throw "Invalid value for 'portRange': expected two ports." }
                $start = ConvertTo-HubInteger -Value $range[0] -Key 'portRange' -Minimum 1 -Maximum 65535
                $end   = ConvertTo-HubInteger -Value $range[1] -Key 'portRange' -Minimum 1 -Maximum 65535
                if ($end -lt $start) { throw "Invalid value for 'portRange': end port is below start port." }
                @($start, $end)
            }
            default { throw "Unsupported setting type for '$key'." }
        }

        if ($merged.PSObject.Properties[$key]) {
            $merged.$key = $coerced
        } else {
            $merged | Add-Member -NotePropertyName $key -NotePropertyValue $coerced -Force
        }
    }

    return $merged
}

function ConvertTo-HubBoolean {
    <#
    .SYNOPSIS
        Coerces a JSON value to a boolean, rejecting anything ambiguous.
    .DESCRIPTION
        [bool]'false' is $true in PowerShell, so string values are matched explicitly.
    .PARAMETER Value
        The value to coerce.
    .PARAMETER Key
        The setting name, used in the error message.
    .EXAMPLE
        ConvertTo-HubBoolean -Value 'true' -Key 'scanOnStartup'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Key
    )

    if ($Value -is [bool]) { return $Value }
    switch ("$Value".Trim().ToLower()) {
        'true'  { return $true }
        'false' { return $false }
        '1'     { return $true }
        '0'     { return $false }
        default { throw "Invalid value for '$Key': expected a boolean." }
    }
}

function ConvertTo-HubInteger {
    <#
    .SYNOPSIS
        Coerces a JSON value to an integer within a range.
    .PARAMETER Value
        The value to coerce.
    .PARAMETER Key
        The setting name, used in the error message.
    .PARAMETER Minimum
        Lowest accepted value.
    .PARAMETER Maximum
        Highest accepted value.
    .EXAMPLE
        ConvertTo-HubInteger -Value 8090 -Key 'defaultPort' -Minimum 1 -Maximum 65535
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][int]$Maximum
    )

    $parsed = 0
    if (-not [int]::TryParse("$Value", [ref]$parsed)) {
        throw "Invalid value for '$Key': expected a number."
    }
    if ($parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "Invalid value for '$Key': must be between $Minimum and $Maximum."
    }
    return $parsed
}
