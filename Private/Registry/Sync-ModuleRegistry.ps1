function Sync-ModuleRegistry {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Discovered)

    $registry = Read-ModuleRegistry
    $added = 0; $updated = 0; $removed = 0

    if ($Discovered -and $Discovered.Count -gt 0) {
        foreach ($mod in $Discovered) {
            if (-not $mod) { continue }
            $existing = $registry.modules | Where-Object { $_.name -eq $mod.Name }

            if ($existing) {
                $existing.path    = $mod.Path
                $existing.version = $mod.Version
                if ($mod.Description) { $existing.description = $mod.Description }
                $existing.lastValidated = (Get-Date).ToUniversalTime().ToString('o')
                $existing.status = 'healthy'

                # Add 'source' property if it doesn't exist on legacy entries
                if (-not ($existing.PSObject.Properties.Name -contains 'source')) {
                    $existing | Add-Member -NotePropertyName 'source' -NotePropertyValue $mod.Source -Force
                } else {
                    $existing.source = $mod.Source
                }

                # Add 'projectUri' property if it doesn't exist
                if (-not ($existing.PSObject.Properties.Name -contains 'projectUri')) {
                    $existing | Add-Member -NotePropertyName 'projectUri' -NotePropertyValue $mod.ProjectUri -Force
                } elseif ($mod.ProjectUri) {
                    $existing.projectUri = $mod.ProjectUri
                }

                $updated++
            } else {
                $entryCmd = $null
                if ($mod.Commands -and $mod.Commands.Count -gt 0) { $entryCmd = $mod.Commands[0] }

                $newEntry = [PSCustomObject]@{
                    name          = $mod.Name
                    path          = $mod.Path
                    description   = $mod.Description
                    version       = $mod.Version
                    category      = 'Uncategorised'
                    tags          = @()
                    author        = $mod.Author
                    entryCommand  = $entryCmd
                    requiresAdmin = $false
                    autoImport    = $false
                    enabled       = $true
                    icon          = 'box'
                    dependencies  = @($mod.Dependencies)
                    source        = if ($mod.Source) { $mod.Source } else { 'custom' }
                    projectUri    = $mod.ProjectUri
                    lastValidated = (Get-Date).ToUniversalTime().ToString('o')
                    status        = 'healthy'
                }
                $registry.modules += $newEntry
                $added++
            }
        }
    }

    foreach ($mod in $registry.modules) {
        if (-not (Test-Path $mod.path)) { $mod.status = 'missing'; $removed++ }
    }

    $registry.lastScanUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-ModuleRegistry -Registry $registry

    Write-HubLog -Level Info -Message "Registry sync: $added added, $updated updated, $removed missing"
    return [PSCustomObject]@{ Added = $added; Updated = $updated; Missing = $removed; Total = $registry.modules.Count }
}
