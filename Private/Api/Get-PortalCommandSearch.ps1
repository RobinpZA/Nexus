function Get-PortalCommandSearch {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [object]$Query
    )
    $searchTerm = $Query['search']
    $registry = Read-ModuleRegistry
    $results = @()

    foreach ($mod in ($registry.modules | Where-Object { $_.enabled })) {
        if (-not (Test-Path $mod.path)) { continue }
        $meta = Get-ModuleMetadata -Path $mod.path
        if (-not $meta -or -not $meta.Commands) { continue }

        foreach ($cmdName in $meta.Commands) {
            if (-not $searchTerm -or $cmdName -match [regex]::Escape($searchTerm)) {
                $verb = $null
                if ($cmdName -match '^([A-Za-z]+)-') { $verb = $Matches[1] }
                $results += @{
                    name     = $cmdName
                    module   = $mod.name
                    category = $mod.category
                    type     = 'Function'
                    verb     = $verb
                }
            }
        }
    }

    Write-JsonResponse -Context $Context -Data @{
        search  = $searchTerm
        count   = $results.Count
        results = $results
    }
}
