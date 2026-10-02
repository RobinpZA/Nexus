function Write-ModuleRegistry {
    <#
    .SYNOPSIS
        Saves the module registry to modules.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Registry
    )

    try {
        # Atomic: an interrupted write must not leave a truncated registry behind.
        Write-AtomicFile -Path $script:RegistryFile -Value ($Registry | ConvertTo-Json -Depth 10)
        Write-HubLog -Level Debug -Message 'Registry saved'
    } catch {
        Write-HubLog -Level Error -Message "Failed to write registry: $($_.Exception.Message)"
        throw
    }
}
