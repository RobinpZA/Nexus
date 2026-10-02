# Test fixture module — no external dependencies, safe to import and execute.

function Get-FixtureValue {
    <#
    .SYNOPSIS
        Echoes its input, for exercising parameter binding.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('one', 'two')][string]$Choice = 'one',
        [int]$Repeat = 1,
        [switch]$Loud
    )

    $value = "$Text/$Choice" * $Repeat
    if ($Loud) { $value = $value.ToUpper() }
    $value
}

function Get-FixtureContext {
    <#
    .SYNOPSIS
        Returns the process that ran the command.
    #>
    [CmdletBinding()]
    param()

    "pid=$PID"
}

function Write-FixtureFailure {
    <#
    .SYNOPSIS
        Emits an error record, for exercising failure reporting.
    #>
    [CmdletBinding()]
    param()

    Write-Error 'fixture failure'
}

function Get-FixtureObject {
    <#
    .SYNOPSIS
        Returns objects, for exercising structured (table) output.
    #>
    [CmdletBinding()]
    param()

    [PSCustomObject]@{ Name = 'alpha'; Count = 1; Enabled = $true }
    [PSCustomObject]@{ Name = 'beta'; Count = 2; Enabled = $false }
}

function Join-FixtureList {
    <#
    .SYNOPSIS
        Describes its typed inputs, for exercising parameter conversion.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Items,
        [int[]]$Numbers,
        [bool]$Flag,
        [int]$Top
    )

    "items=$($Items -join '|');numbers=$(($Numbers | Measure-Object -Sum).Sum);flag=$Flag;top=$($Top + 1)"
}
