function Get-OpsModule {
    <#
    .SYNOPSIS
        Lists registered modules from the Nexus registry.
    .PARAMETER Name
        Filter by module name (supports wildcards).
    .PARAMETER Category
        Filter by category.
    .PARAMETER Tag
        Filter by tag.
    .PARAMETER Status
        Filter by status (healthy, missing, unknown, error).
    .EXAMPLE
        Get-OpsModule
    .EXAMPLE
        Get-OpsModule -Category Security
    .EXAMPLE
        Get-OpsModule -Tag "M365"
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Category,
        [string]$Tag,
        [ValidateSet('healthy', 'missing', 'unknown', 'error')]
        [string]$Status
    )

    $registry = Read-ModuleRegistry
    $modules = $registry.modules | Where-Object { $_.enabled }

    if ($Name) {
        $modules = $modules | Where-Object { $_.name -like $Name }
    }
    if ($Category) {
        $modules = $modules | Where-Object { $_.category -eq $Category }
    }
    if ($Tag) {
        $modules = $modules | Where-Object { $Tag -in $_.tags }
    }
    if ($Status) {
        $modules = $modules | Where-Object { $_.status -eq $Status }
    }

    if (-not $modules) {
        Write-HubLog -Level Info -Message 'No modules match the specified filters'
        return
    }

    $modules | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.name
            Category    = $_.category
            Version     = $_.version
            Status      = $_.status
            Description = $_.description
            Tags        = ($_.tags -join ', ')
            Path        = $_.path
            EntryCmd    = $_.entryCommand
        }
    } | Format-Table -AutoSize
}
