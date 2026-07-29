function Get-CommandMetadataScript {
    <#
    .SYNOPSIS
        Returns the reflection script used to describe a command inside its own context.
    .DESCRIPTION
        Parameter metadata must be read where the module is loaded — the runspace or the
        child process — never in the Nexus process. Importing a module here to call
        Get-Command loads its dependencies (Graph, EXO, Teams) into the listener's own
        session, which is exactly the DLL conflict the isolation is there to prevent.

        The same text is used by both isolation modes: runspaces run it directly, and
        process contexts get it written to disk as a .ps1 next to their comms files.
    .EXAMPLE
        $ps.AddScript((Get-CommandMetadataScript)).AddArgument('Get-Thing')
    #>
    [CmdletBinding()]
    param()

    return @'
param($CommandName)

$cmd = Get-Command -Name $CommandName -ErrorAction Stop

$commonParams = @(
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
    'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
    'OutBuffer', 'PipelineVariable', 'ProgressAction', 'WhatIf', 'Confirm'
)

$parameters = @()
foreach ($entry in $cmd.Parameters.GetEnumerator()) {
    if ($entry.Key -in $commonParams) { continue }

    $p = $entry.Value
    $mandatory = $false
    $position = -1
    $helpMessage = $null
    $validateSet = $null

    foreach ($attr in $p.Attributes) {
        if ($attr -is [System.Management.Automation.ParameterAttribute]) {
            $mandatory = $attr.Mandatory
            $position = $attr.Position
            if ($attr.HelpMessage) { $helpMessage = $attr.HelpMessage }
        }
        if ($attr -is [System.Management.Automation.ValidateSetAttribute]) {
            $validateSet = @($attr.ValidValues)
        }
    }

    $parameters += [PSCustomObject]@{
        name         = $entry.Key
        type         = $p.ParameterType.Name
        mandatory    = $mandatory
        position     = $position
        helpMessage  = $helpMessage
        validateSet  = $validateSet
        defaultValue = $null
        aliases      = @($p.Aliases)
    }
}

$help = Get-Help $CommandName -ErrorAction SilentlyContinue

[PSCustomObject]@{
    command     = $CommandName
    synopsis    = if ($help -and $help.Synopsis) { $help.Synopsis.Trim() } else { $null }
    description = if ($help -and $help.Description) { ($help.Description | Out-String).Trim() } else { $null }
    parameters  = $parameters
}
'@
}

function Get-CommandSynopsisScript {
    <#
    .SYNOPSIS
        Returns the script that collects Get-Help synopses inside a module's own context.
    .DESCRIPTION
        Companion to Get-CommandMetadataScript for the portal's "Load Descriptions"
        action, which would otherwise import the module into the Nexus process.
    .EXAMPLE
        $ps.AddScript((Get-CommandSynopsisScript)).AddArgument(@('Get-Thing'))
    #>
    [CmdletBinding()]
    param()

    return @'
param($CommandNames)

$result = @{}
foreach ($name in @($CommandNames)) {
    try {
        $help = Get-Help $name -ErrorAction SilentlyContinue
        if ($help -and $help.Synopsis) {
            $synopsis = $help.Synopsis.Trim()
            # Skip the default synopsis, which is just the command name repeated.
            if ($synopsis.Length -gt 0 -and $synopsis -ne $name) { $result[$name] = $synopsis }
        }
    } catch {
        Write-Debug "No help for $name"
    }
}

[PSCustomObject]$result
'@
}
