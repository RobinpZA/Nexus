function Read-ModuleRegistry {
    <#
    .SYNOPSIS
        Loads the module registry from modules.json.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:RegistryFile)) {
        Write-HubLog -Level Warning -Message "Registry file not found: $($script:RegistryFile)"
        return @{
            version     = '1.0'
            lastScanUtc = $null
            scanRoots   = @()
            modules     = @()
        }
    }

    try {
        $raw = Get-Content -Path $script:RegistryFile -Raw -Encoding utf8
        $registry = $raw | ConvertFrom-Json
        Write-HubLog -Level Debug -Message "Registry loaded: $($registry.modules.Count) modules"
        return $registry
    } catch {
        Write-HubLog -Level Error -Message "Failed to read registry: $($_.Exception.Message)"
        return @{
            version     = '1.0'
            lastScanUtc = $null
            scanRoots   = @()
            modules     = @()
        }
    }
}
