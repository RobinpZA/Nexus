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
        $Registry | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:RegistryFile -Encoding utf8 -Force
        Write-HubLog -Level Debug -Message 'Registry saved'
    } catch {
        Write-HubLog -Level Error -Message "Failed to write registry: $($_.Exception.Message)"
        throw
    }
}
