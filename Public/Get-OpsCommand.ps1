function Get-OpsCommand {
    <#
    .SYNOPSIS
        Lists or searches commands across all registered modules.
        Reads from manifests — does not import modules.
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

    $allCommands | Format-Table -AutoSize
}
