function Import-RegisteredModule {
    <#
    .SYNOPSIS
        Imports a module by its registry entry. Tracks import state to avoid re-importing.
        Does NOT use -Global to prevent function name collisions with Nexus internals.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ModuleEntry
    )

    $name = $ModuleEntry.name
    $path = $ModuleEntry.path

    # Check if already imported this session
    if ($script:ImportedModules.ContainsKey($name)) {
        Write-HubLog -Level Debug -Message "Module already imported: $name"
        return $true
    }

    # Validate path
    if (-not (Test-Path $path)) {
        Write-HubLog -Level Error -Message "Module path not found: $path"
        return $false
    }

    try {
        # Do NOT use -Global — child modules like TeamsVoiceManager and CAReporter
        # have identically named private functions (Write-HubLog, Start-HttpListener, etc.)
        # Using -Global overwrites Nexus functions and crashes the listener.
        Import-Module $path -Force -DisableNameChecking -ErrorAction Stop

        $script:ImportedModules[$name] = @{
            Path       = $path
            ImportedAt = Get-Date
        }
        Write-HubLog -Level Info -Message "Imported module: $name"
        return $true
    } catch {
        Write-HubLog -Level Error -Message "Failed to import $name : $($_.Exception.Message)"
        return $false
    }
}
