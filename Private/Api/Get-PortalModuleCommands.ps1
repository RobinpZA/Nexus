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
        # Import the module to access Get-Help
        $imported = Import-RegisteredModule -ModuleEntry $mod
        if ($imported) {
            foreach ($cmdName in $meta.Commands) {
                try {
                    $help = Get-Help $cmdName -ErrorAction SilentlyContinue
                    if ($help -and $help.Synopsis) {
                        $synopsis = $help.Synopsis.Trim()
                        # Skip unhelpful default synopsis (just the command name repeated)
                        if ($synopsis -ne $cmdName -and $synopsis.Length -gt 0) {
                            $descriptions[$cmdName] = $synopsis
                        }
                    }
                } catch { }
            }
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
