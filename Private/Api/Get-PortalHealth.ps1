function Get-PortalHealth {
    <#
    .SYNOPSIS
        API handler: GET /api/health — returns health status of all registered modules.
    .DESCRIPTION
        The only API route open without the session token, so the auto-start profile block
        can tell whether Nexus is already running. Unauthenticated callers get the summary
        only — module names and paths are registry contents, not liveness.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .PARAMETER Detailed
        Include per-module names, paths and status. Set when the request is authenticated.
    .EXAMPLE
        Get-PortalHealth -Context $Context -Detailed
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext]$Context,
        [switch]$Detailed
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

    $data = @{
        status  = if ($healthy -eq $total) { 'healthy' } else { 'degraded' }
        healthy = $healthy
        total   = $total
    }
    if ($Detailed) { $data.modules = $modules }

    Write-JsonResponse -Context $Context -Data $data
}
