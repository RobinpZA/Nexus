function Get-PortalHealth {
    <#
    .SYNOPSIS
        API handler: GET /api/health — returns health status of all registered modules.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext]$Context
    )

    $registry = Read-ModuleRegistry
    # Keep health aligned with the portal module list, which only shows enabled modules.
    $activeModules = @($registry.modules | Where-Object { $_.enabled })
    $modules = @()

    foreach ($mod in $activeModules) {
        $pathExists = Test-Path $mod.path
        $status = if ($pathExists) { 'healthy' } else { 'missing' }

        $modules += @{
            name   = $mod.name
            status = $status
            path   = $mod.path
        }
    }

    $healthy = ($modules | Where-Object { $_.status -eq 'healthy' }).Count
    $total   = $modules.Count

    Write-JsonResponse -Context $Context -Data @{
        status  = if ($healthy -eq $total) { 'healthy' } else { 'degraded' }
        healthy = $healthy
        total   = $total
        modules = $modules
    }
}
