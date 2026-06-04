function Unregister-OpsModule {
    <#
    .SYNOPSIS
        Removes a module from the Nexus registry.
    .PARAMETER Name
        The module name to remove.
    .EXAMPLE
        Unregister-OpsModule -Name "MyTool"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )

    $registry = Read-ModuleRegistry
    $mod = $registry.modules | Where-Object { $_.name -eq $Name }

    if (-not $mod) {
        Write-Error "Module '$Name' is not registered."
        return
    }

    $registry.modules = @($registry.modules | Where-Object { $_.name -ne $Name })
    Write-ModuleRegistry -Registry $registry

    # Remove from imported cache
    if ($script:ImportedModules.ContainsKey($Name)) {
        Remove-Module $Name -Force -ErrorAction SilentlyContinue
        $script:ImportedModules.Remove($Name)
    }

    Write-Host "  ✓ Module '$Name' unregistered" -ForegroundColor Green
}
