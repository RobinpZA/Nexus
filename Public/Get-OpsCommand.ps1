function Get-OpsCommand {
    <#
    .SYNOPSIS
        Lists or searches commands across all registered modules.
    .DESCRIPTION
        Reads the exported command names from each enabled module's manifest, so modules are
        not imported. Emits one Nexus.Command object per command (Command, Module, Category,
        Type), which can be piped to Where-Object, Select-Object and so on. The console shows
        them as a table. Writes an Info log entry and returns nothing when nothing matches.
    .PARAMETER Module
        Filter commands to a specific module.
    .PARAMETER Search
        Search commands by keyword (matches command name).
    .PARAMETER Tag
        Filter to modules matching a specific tag, then show their commands.
    .EXAMPLE
        Get-OpsCommand
    .EXAMPLE
        Get-OpsCommand -Module CA-BaselineAuditor
    .EXAMPLE
        Get-OpsCommand -Search "report"
    .EXAMPLE
        Get-OpsCommand -Tag M365 | Where-Object Module -like 'CA-*'
    #>
    [CmdletBinding()]
    param(
        [string]$Module,
        [string]$Search,
        [string]$Tag
    )

    $registry = Read-ModuleRegistry
    $targetModules = $registry.modules | Where-Object { $_.enabled }

    if ($Module) {
        $targetModules = $targetModules | Where-Object { $_.name -eq $Module }
    }
    if ($Tag) {
        $targetModules = $targetModules | Where-Object { $Tag -in $_.tags }
    }

    $allCommands = @()

    foreach ($mod in $targetModules) {
        if (-not (Test-Path $mod.path)) { continue }

        # Read commands from manifest — no import needed
        $meta = Get-ModuleMetadata -Path $mod.path
        if (-not $meta -or -not $meta.Commands) { continue }

        foreach ($cmdName in $meta.Commands) {
            if ($Search -and $cmdName -notmatch [regex]::Escape($Search)) { continue }

            $allCommands += [PSCustomObject]@{
                PSTypeName = 'Nexus.Command'
                Command  = $cmdName
                Module   = $mod.name
                Category = $mod.category
                Type     = 'Function'
            }
        }
    }

    if ($allCommands.Count -eq 0) {
        Write-HubLog -Level Info -Message 'No commands found matching the specified criteria'
        return
    }

    $allCommands
}
