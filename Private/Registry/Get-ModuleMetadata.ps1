function Get-ModuleMetadata {
    <#
    .SYNOPSIS
        Extracts metadata from a .psd1 manifest.
        Primary: Import-PowerShellDataFile (fast, no dependency validation).
        Fallback: Test-ModuleManifest (handles dynamic expressions like if($PSEdition)).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ForceSource
    )

    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $data       = $null

    # Parsing every manifest on every request cost ~1.6s warm (9s cold, over OneDrive)
    # on a 227-module registry, and the listener is single-threaded. Cache on the file's
    # write stamp so an edited manifest is still picked up.
    $cacheKey = "$Path|$ForceSource"
    $stamp    = $null
    try {
        $file  = Get-Item -LiteralPath $Path -ErrorAction Stop
        $stamp = "$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
        if ($script:MetadataCache -and $script:MetadataCache.ContainsKey($cacheKey) -and
            $script:MetadataCache[$cacheKey].Stamp -eq $stamp) {
            return $script:MetadataCache[$cacheKey].Data
        }
    } catch {
        Write-HubLog -Level Debug -Message "Cannot stat manifest ${moduleName}: $($_.Exception.Message)"
    }

    # ── Primary: Import-PowerShellDataFile (fast, no dependency check) ──
    try {
        $data = Import-PowerShellDataFile -Path $Path -ErrorAction Stop
    } catch {
        # If it fails (e.g. dynamic expressions like if($PSEdition)), fall back
        Write-HubLog -Level Debug -Message "Import-PowerShellDataFile failed for ${moduleName}, trying Test-ModuleManifest fallback"
    }

    # ── Fallback: Test-ModuleManifest (evaluates dynamic expressions) ──
    if (-not $data) {
        try {
            $manifest = Test-ModuleManifest -Path $Path -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

            if ($manifest) {
                $commands = @()
                $commands += @($manifest.ExportedFunctions.Keys)
                $commands += @($manifest.ExportedCmdlets.Keys)

                $dependencies = @($manifest.RequiredModules | ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($_.Name) { $_.Name }
                    else { $_.ToString() }
                })

                $version = if ($manifest.Version) { $manifest.Version.ToString() } else { '0.0.0' }

                $source = 'custom'
                if ($ForceSource) { $source = $ForceSource }
                else {
                    $psModulePaths = @($env:PSModulePath -split [IO.Path]::PathSeparator)
                    foreach ($mp in $psModulePaths) {
                        if ($mp -and $Path.StartsWith($mp, [System.StringComparison]::OrdinalIgnoreCase)) { $source = 'published'; break }
                    }
                }

                $projectUri = $null
                if ($manifest.PrivateData -and $manifest.PrivateData.PSData -and $manifest.PrivateData.PSData.ProjectUri) {
                    $projectUri = $manifest.PrivateData.PSData.ProjectUri
                }

                $result = [PSCustomObject]@{
                    Name         = $moduleName
                    Path         = $Path
                    Description  = if ($manifest.Description) { $manifest.Description } else { '' }
                    Version      = $version
                    Author       = if ($manifest.Author) { $manifest.Author } else { '' }
                    Commands     = $commands
                    Dependencies = $dependencies
                    Source       = $source
                    ProjectUri   = $projectUri
                }
                Set-MetadataCacheEntry -Key $cacheKey -Stamp $stamp -Data $result
                return $result
            }
        } catch {
            Write-HubLog -Level Debug -Message "Test-ModuleManifest also failed for ${moduleName}: $($_.Exception.Message)"
        }

        # Both methods failed
        Write-HubLog -Level Warning -Message "Cannot read manifest: $moduleName ($Path)"
        return $null
    }

    # ── Process Import-PowerShellDataFile result ──
    $commands = @()
    if ($data.FunctionsToExport) { $commands += @($data.FunctionsToExport | Where-Object { $_ -and $_ -ne '*' }) }
    if ($data.CmdletsToExport)  { $commands += @($data.CmdletsToExport  | Where-Object { $_ -and $_ -ne '*' }) }

    $dependencies = @()
    if ($data.RequiredModules) {
        $dependencies = @($data.RequiredModules | ForEach-Object {
            if ($_ -is [string]) { $_ }
            elseif ($_ -is [hashtable] -and $_.ModuleName) { $_.ModuleName }
            else { $_.ToString() }
        })
    }

    $version = '0.0.0'
    if ($data.ModuleVersion) { $version = $data.ModuleVersion.ToString() }

    $source = 'custom'
    if ($ForceSource) { $source = $ForceSource }
    else {
        $psModulePaths = @($env:PSModulePath -split [IO.Path]::PathSeparator)
        foreach ($mp in $psModulePaths) {
            if ($mp -and $Path.StartsWith($mp, [System.StringComparison]::OrdinalIgnoreCase)) { $source = 'published'; break }
        }
    }

    $projectUri = $null
    if ($data.PrivateData -and $data.PrivateData.PSData -and $data.PrivateData.PSData.ProjectUri) {
        $projectUri = $data.PrivateData.PSData.ProjectUri
    }

    $result = [PSCustomObject]@{
        Name         = $moduleName
        Path         = $Path
        Description  = if ($data.Description) { $data.Description } else { '' }
        Version      = $version
        Author       = if ($data.Author) { $data.Author } else { '' }
        Commands     = $commands
        Dependencies = $dependencies
        Source       = $source
        ProjectUri   = $projectUri
    }
    Set-MetadataCacheEntry -Key $cacheKey -Stamp $stamp -Data $result
    return $result
}

function Set-MetadataCacheEntry {
    <#
    .SYNOPSIS
        Stores parsed manifest metadata against the file stamp it was read from.
    .PARAMETER Key
        Cache key (manifest path and forced source).
    .PARAMETER Stamp
        Write-time and length of the manifest when it was parsed.
    .PARAMETER Data
        The parsed metadata object.
    .EXAMPLE
        Set-MetadataCacheEntry -Key $key -Stamp $stamp -Data $meta
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][string]$Stamp,
        [Parameter(Mandatory)][object]$Data
    )

    if (-not $Stamp) { return }
    if ($null -eq $script:MetadataCache) { $script:MetadataCache = @{} }
    $script:MetadataCache[$Key] = @{ Stamp = $Stamp; Data = $Data }
}

function Clear-MetadataCache {
    <#
    .SYNOPSIS
        Empties the manifest metadata cache.
    .DESCRIPTION
        Entries expire on their own when a manifest is rewritten; this is for a scan,
        where modules may have been added, moved or removed wholesale.
    .EXAMPLE
        Clear-MetadataCache
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess('module metadata cache', 'Clear')) {
        $script:MetadataCache = @{}
    }
}
