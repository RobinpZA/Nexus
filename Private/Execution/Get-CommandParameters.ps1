function Get-CommandParameters {
    <#
    .SYNOPSIS
        Reflects parameter metadata for a given command (name, type, mandatory, default, validateSet).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    try {
        $cmd = Get-Command $CommandName -ErrorAction Stop
    } catch {
        Write-HubLog -Level Error -Message "Command not found: $CommandName"
        return $null
    }

    # Common parameters to exclude from the UI
    $commonParams = @(
        'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
        'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
        'OutBuffer', 'PipelineVariable', 'ProgressAction', 'WhatIf', 'Confirm'
    )

    $parameters = @()

    foreach ($param in $cmd.Parameters.GetEnumerator()) {
        if ($param.Key -in $commonParams) { continue }

        $p = $param.Value
        $attrs = $p.Attributes

        $mandatory = $false
        $position  = -1
        $helpMsg   = $null
        $validateSet = $null

        foreach ($attr in $attrs) {
            if ($attr -is [System.Management.Automation.ParameterAttribute]) {
                $mandatory = $attr.Mandatory
                $position  = $attr.Position
                if ($attr.HelpMessage) { $helpMsg = $attr.HelpMessage }
            }
            if ($attr -is [System.Management.Automation.ValidateSetAttribute]) {
                $validateSet = @($attr.ValidValues)
            }
        }

        $parameters += [PSCustomObject]@{
            name         = $param.Key
            type         = $p.ParameterType.Name
            mandatory    = $mandatory
            position     = $position
            helpMessage  = $helpMsg
            validateSet  = $validateSet
            defaultValue = $null
            aliases      = @($p.Aliases)
        }
    }

    # Get help info for synopsis
    $help = Get-Help $CommandName -ErrorAction SilentlyContinue
    $synopsis = if ($help.Synopsis) { $help.Synopsis.Trim() } else { $null }
    $description = if ($help.Description) { ($help.Description | Out-String).Trim() } else { $null }

    return [PSCustomObject]@{
        command     = $CommandName
        synopsis    = $synopsis
        description = $description
        parameters  = $parameters
    }
}
