function Import-OpsModule {
    <#
    .SYNOPSIS
        Imports a registered module by its friendly name.
    .PARAMETER Name
        The registered module name (as it appears in modules.json).
    .EXAMPLE
        Import-OpsModule -Name CA-BaselineAuditor
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )

    $registry = Read-ModuleRegistry
    $mod = $registry.modules | Where-Object { $_.name -eq $Name -and $_.enabled }

    if (-not $mod) {
        Write-HubLog -Level Error -Message "Module not found or disabled: $Name"
        Write-Error "Module '$Name' is not registered or is disabled. Use Get-OpsModule to see available modules."
        return
    }

    $result = Import-RegisteredModule -ModuleEntry $mod

    if ($result) {
        Write-Host "  ✓ Module '$Name' imported successfully" -ForegroundColor Green
        Write-Host "    Commands: $(( Get-Command -Module $Name -ErrorAction SilentlyContinue | Measure-Object ).Count)" -ForegroundColor DarkGray
    } else {
        Write-Error "Failed to import module '$Name'. Check the log for details."
    }
}
