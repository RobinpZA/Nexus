function Get-PortalModuleList {
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)
    $registry = Read-ModuleRegistry
    $modules = @($registry.modules | Where-Object { $_.enabled } | ForEach-Object {
        $status = if (Test-Path $_.path) { 'healthy' } else { 'missing' }
        @{
            name = $_.name; description = $_.description; version = $_.version; category = $_.category
            tags = @($_.tags); author = $_.author; entryCommand = $_.entryCommand; icon = $_.icon
            status = $status; source = if ($_.source) { $_.source } else { 'custom' }
            requiresAdmin = $_.requiresAdmin; dependencies = @($_.dependencies)
            lastValidated = $_.lastValidated; projectUri = $_.projectUri
        }
    })
    Write-JsonResponse -Context $Context -Data @{ count = $modules.Count; modules = $modules }
}
