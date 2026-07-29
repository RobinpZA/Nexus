function Get-PortalModuleCommands {
    <#
    .SYNOPSIS
        API handler: GET /api/modules/{name}/commands
        Returns commands categorized by verb group with quick-start highlights.
        Add ?describe=true to fetch Get-Help synopsis (requires module import, slower).
    #>
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$ModuleName
    )

    $registry = Read-ModuleRegistry
    $mod = $registry.modules | Where-Object { $_.name -eq $ModuleName }

    if (-not $mod) {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Module not found: $ModuleName"
        return
    }
    if (-not (Test-Path $mod.path)) {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Module path not found"
        return
    }

    # Read commands from manifest (no import)
    $meta = Get-ModuleMetadata -Path $mod.path
    if (-not $meta -or -not $meta.Commands -or $meta.Commands.Count -eq 0) {
        Write-JsonResponse -Context $Context -Data @{
            module = $ModuleName; count = 0; commands = @(); categories = @()
            quickStart = @{ connection = @(); primary = @() }
        }
        return
    }

    # Categorize commands
    $catResult = Get-CommandCategories -Commands $meta.Commands

    # Check if descriptions were requested
    $wantDescriptions = $Context.Request.QueryString['describe'] -eq 'true'
    $descriptions = @{}

    if ($wantDescriptions) {
        # Collected inside the module's own context — importing it here would load its
        # dependencies (Graph, EXO, Teams) into the listener process.
        $info = Get-ContextCommandSynopsis -ModuleEntry $mod -CommandNames @($meta.Commands)
        if ($info.status -eq 'ok' -and $info.data) {
            foreach ($property in $info.data.PSObject.Properties) {
                $descriptions[$property.Name] = $property.Value
            }
        } else {
            Write-HubLog -Level Warning -Message "Descriptions unavailable for $ModuleName : $($info.message)"
        }
    }

    # Flatten commands list with descriptions
    $flatCommands = @($meta.Commands | ForEach-Object {
        @{
            name        = $_
            module      = $ModuleName
            type        = 'Function'
            description = if ($descriptions.ContainsKey($_)) { $descriptions[$_] } else { $null }
        }
    })

    # Add descriptions to categorized commands too
    foreach ($cat in $catResult.categories) {
        foreach ($cmd in $cat.commands) {
            if ($descriptions.ContainsKey($cmd.name)) {
                $cmd['description'] = $descriptions[$cmd.name]
            }
        }
    }

    Write-JsonResponse -Context $Context -Data @{
        module     = $ModuleName
        count      = $meta.Commands.Count
        commands   = $flatCommands
        categories = @($catResult.categories)
        quickStart = @{
            connection = @($catResult.quickStart.connection)
            primary    = @($catResult.quickStart.primary)
        }
    }
}
