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

function Get-FixtureThenThrow {
    <#
    .SYNOPSIS
        Emits three records, then raises a terminating error.
    #>
    [CmdletBinding()]
    param()

    'one'
    'two'
    'three'
    throw 'fixture boom'
}

function Get-FixtureRows {
    <#
    .SYNOPSIS
        Emits Count structured records, for exercising the output cap.
    #>
    [CmdletBinding()]
    param([int]$Count = 5)

    foreach ($i in 1..$Count) { [PSCustomObject]@{ Index = $i } }
}

function Get-FixtureZero {
    <#
    .SYNOPSIS
        Emits a single 0, which is falsy.
    #>
    [CmdletBinding()]
    param()

    0
}

function Wait-FixtureSlow {
    <#
    .SYNOPSIS
        Emits one record, then sleeps (interruptible), for exercising cancellation.
    #>
    [CmdletBinding()]
    param([int]$Seconds = 30)

    'working'
    Start-Sleep -Seconds $Seconds
    'finished'
}

function Wait-FixtureBlocking {
    <#
    .SYNOPSIS
        Emits one record, then blocks in a .NET call that a stop request cannot interrupt.
    #>
    [CmdletBinding()]
    param([int]$Seconds = 12)

    'working'
    [System.Threading.Thread]::Sleep($Seconds * 1000)
    'finished'
}
