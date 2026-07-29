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
