function Unregister-OpsModule {
    <#
    .SYNOPSIS
        Removes a module from the Nexus registry.
    .DESCRIPTION
        Removes the registry entry, drops the module from the imported cache and stops its
        runspace or worker process. Supports -WhatIf.
    .PARAMETER Name
        The module name to remove.
    .EXAMPLE
        Unregister-OpsModule -Name "MyTool"
        Removes MyTool and stops its context.
    .EXAMPLE
        Unregister-OpsModule -Name 'MyTool' -WhatIf
        Shows what would be removed without changing anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
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

    if (-not $PSCmdlet.ShouldProcess($Name, 'Unregister module')) { return }

    $registry.modules = @($registry.modules | Where-Object { $_.name -ne $Name })
    Write-ModuleRegistry -Registry $registry

    # Stop the module's runspace or worker so it does not outlive its registration.
    Stop-ModuleContext -Name $Name

    # Remove from imported cache
    if ($script:ImportedModules.ContainsKey($Name)) {
        Remove-Module $Name -Force -ErrorAction SilentlyContinue
        $script:ImportedModules.Remove($Name)
    }

    Write-Host "  ✓ Module '$Name' unregistered" -ForegroundColor Green
}
