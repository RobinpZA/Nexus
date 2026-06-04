function Register-OpsModule {
    <#
    .SYNOPSIS
        Adds a new module to the Nexus registry.
    .PARAMETER Name
        Friendly name for the module.
    .PARAMETER Path
        Full path to the module's .psd1 manifest file.
    .PARAMETER Category
        Module category (e.g., Security, Identity, Teams, Utility).
    .PARAMETER Tags
        Array of searchable tags.
    .PARAMETER Description
        Optional description (auto-detected from manifest if not provided).
    .PARAMETER EntryCommand
        Primary command to launch (optional).
    .PARAMETER Icon
        Icon name for the portal card (default: 'box').
    .EXAMPLE
        Register-OpsModule -Name "MyTool" -Path "C:\Tools\MyTool\MyTool.psd1" -Category "Utility"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Mandatory, Position = 1)]
        [string]$Path,

        [string]$Category = 'Uncategorised',
        [string[]]$Tags = @(),
        [string]$Description,
        [string]$EntryCommand,
        [string]$Icon = 'box'
    )

    # Validate path
    $validation = Test-ModulePath -Path $Path
    if (-not $validation.Exists) {
        Write-Error "Path does not exist: $Path"
        return
    }
    if (-not $validation.Valid) {
        Write-Warning "Manifest validation warning: $($validation.Error)"
    }

    # Check for duplicate
    $registry = Read-ModuleRegistry
    $existing = $registry.modules | Where-Object { $_.name -eq $Name }
    if ($existing) {
        Write-Error "Module '$Name' is already registered. Use Unregister-OpsModule first to re-register."
        return
    }

    # Extract metadata
    $meta = Get-ModuleMetadata -Path $Path

    $newEntry = [PSCustomObject]@{
        name          = $Name
        path          = $Path
        description   = if ($Description) { $Description } elseif ($meta) { $meta.Description } else { '' }
        version       = if ($meta) { $meta.Version } else { '0.0.0' }
        category      = $Category
        tags          = $Tags
        author        = if ($meta) { $meta.Author } else { '' }
        entryCommand  = if ($EntryCommand) { $EntryCommand } elseif ($meta -and $meta.Commands.Count -gt 0) { $meta.Commands[0] } else { $null }
        requiresAdmin = $false
        autoImport    = $false
        enabled       = $true
        icon          = $Icon
        dependencies  = if ($meta) { @($meta.Dependencies) } else { @() }
        lastValidated = (Get-Date).ToUniversalTime().ToString('o')
        status        = 'healthy'
    }

    $registry.modules += $newEntry
    Write-ModuleRegistry -Registry $registry

    Write-Host "  ✓ Module '$Name' registered successfully" -ForegroundColor Green
    Write-Host "    Path: $Path" -ForegroundColor DarkGray
    Write-Host "    Commands: $(if ($meta) { $meta.Commands.Count } else { 'unknown' })" -ForegroundColor DarkGray
}
