function Invoke-OpsCommand {
    <#
    .SYNOPSIS
        Runs a command from a registered module. Handles import, parameter binding, and output capture.
    .PARAMETER Module
        The registered module name.
    .PARAMETER Command
        The command to invoke.
    .PARAMETER Parameters
        A hashtable of parameters to pass to the command.
    .EXAMPLE
        Invoke-OpsCommand -Module CA-BaselineAuditor -Command Invoke-CABaselineAudit -Parameters @{ OpenReport = $true }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Module,

        [Parameter(Mandatory, Position = 1)]
        [string]$Command,

        [hashtable]$Parameters = @{}
    )

    $registry = Read-ModuleRegistry
    $mod = $registry.modules | Where-Object { $_.name -eq $Module -and $_.enabled }

    if (-not $mod) {
        Write-Error "Module '$Module' is not registered or is disabled."
        return
    }

    $result = Invoke-RegisteredCommand -ModuleEntry $mod -CommandName $Command -Parameters $Parameters

    # Display output
    foreach ($line in $result.output) {
        $colour = switch ($line.stream) {
            'Error'       { 'Red' }
            'Warning'     { 'Yellow' }
            'Verbose'     { 'DarkGray' }
            'Debug'       { 'DarkGray' }
            'Information' { 'Cyan' }
            default       { 'White' }
        }
        Write-Host "  [$($line.stream)] $($line.message)" -ForegroundColor $colour
    }

    Write-Host ''
    if ($result.success) {
        Write-Host "  ✓ Completed in $($result.durationMs)ms" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Failed after $($result.durationMs)ms" -ForegroundColor Red
    }

    return $result
}
