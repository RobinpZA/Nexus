function Invoke-ModuleScan {
    [CmdletBinding()]
    param(
        [string[]]$ScanRoots, [int]$MaxDepth = 2,
        [string[]]$Exclude = @('node_modules', '.git', 'bin', 'obj', 'build', 'Tests'),
        [switch]$IncludePublished, [string[]]$PublishedModulePaths
    )

    $discovered = [System.Collections.Generic.List[PSCustomObject]]::new()
    $discoveredNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Build a list of known PSModulePath locations to detect published modules
    $psModulePaths = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') })

    foreach ($root in $ScanRoots) {
        if (-not (Test-Path $root)) { Write-HubLog -Level Warning -Message "Scan root not found: $root"; continue }
        Write-HubLog -Level Info -Message "Scanning: $root (depth: $MaxDepth)"

        # Determine if this scan root is a PSModulePath location
        $rootNorm = $root.TrimEnd('\', '/')
        $rootIsPublished = $psModulePaths | Where-Object { $rootNorm -eq $_ -or $rootNorm.StartsWith($_ + '\') -or $rootNorm.StartsWith($_ + '/') }

        $psd1Files = @(Get-ChildItem -Path $root -Filter '*.psd1' -Recurse -Depth $MaxDepth -ErrorAction SilentlyContinue)
        Write-HubLog -Level Info -Message "  Found $($psd1Files.Count) .psd1 file(s)"

        foreach ($file in $psd1Files) {
            $skip = $false
            $pathParts = $file.DirectoryName -split '[\\\/]'
            foreach ($ex in $Exclude) { if ($pathParts -contains $ex) { $skip = $true; break } }
            if ($skip) { continue }

            $parentName      = $file.Directory.Name
            $baseName        = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $grandParentName = if ($file.Directory.Parent) { $file.Directory.Parent.Name } else { '' }

            $isStandard  = ($parentName -eq $baseName)
            $isVersioned = ($grandParentName -eq $baseName) -and ($parentName -match '^\d+\.')

            if (-not $isStandard -and -not $isVersioned) { continue }
            if ($discoveredNames.Contains($baseName)) { continue }

            if ($isVersioned) {
                $versionFolders = @(Get-ChildItem -Path $file.Directory.Parent.FullName -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d+\.' } |
                    Sort-Object { try { [version]($_.Name -replace '[^\d.]','') } catch { [version]'0.0' } } -Descending)
                if ($versionFolders.Count -gt 0 -and $versionFolders[0].Name -ne $parentName) { continue }
            }

            # Auto-detect source: if the scan root is under PSModulePath, it's published
            $source = if ($rootIsPublished) { 'published' } else { 'custom' }

            $meta = Get-ModuleMetadata -Path $file.FullName -ForceSource $source
            if ($meta) {
                $discovered.Add($meta)
                $null = $discoveredNames.Add($baseName)
                Write-HubLog -Level Info -Message "  ✓ Discovered ($source): $($meta.Name) ($($meta.Commands.Count) commands)"
            }
        }
    }

    # ── Published modules (explicit PSModulePath scan) ──
    if ($IncludePublished) {
        $pubPaths = if ($PublishedModulePaths -and $PublishedModulePaths.Count -gt 0) { $PublishedModulePaths } else { $psModulePaths }
        $skipSystem = @('Microsoft.PowerShell.', 'PSReadLine', 'PackageManagement', 'PowerShellGet', 'ThreadJob', 'PSDesiredStateConfiguration')
        foreach ($pubRoot in $pubPaths) {
            if (-not (Test-Path $pubRoot)) { continue }
            # Skip if this path is already in the scan roots (already scanned above)
            $pubNorm = $pubRoot.TrimEnd('\', '/')
            $alreadyScanned = $ScanRoots | Where-Object { $_.TrimEnd('\', '/') -eq $pubNorm }
            if ($alreadyScanned) { continue }

            Write-HubLog -Level Info -Message "Scanning published: $pubRoot"
            $moduleFolders = @(Get-ChildItem -Path $pubRoot -Directory -ErrorAction SilentlyContinue)
            foreach ($folder in $moduleFolders) {
                $modName = $folder.Name
                $isSystem = $false
                foreach ($prefix in $skipSystem) { if ($modName.StartsWith($prefix)) { $isSystem = $true; break } }
                if ($isSystem) { continue }
                if ($discoveredNames.Contains($modName)) { continue }

                $directPsd1 = Join-Path $folder.FullName "$modName.psd1"
                if (Test-Path $directPsd1) {
                    $meta = Get-ModuleMetadata -Path $directPsd1 -ForceSource 'published'
                    if ($meta) { $discovered.Add($meta); $null = $discoveredNames.Add($modName); Write-HubLog -Level Info -Message "  ✓ Discovered (published): $($meta.Name) v$($meta.Version)" }
                    continue
                }

                $versionFolders = @(Get-ChildItem -Path $folder.FullName -Directory -ErrorAction SilentlyContinue |
                    Sort-Object { try { [version]($_.Name -replace '[^\d.]','') } catch { [version]'0.0' } } -Descending)
                foreach ($vf in $versionFolders) {
                    $versionedPsd1 = Join-Path $vf.FullName "$modName.psd1"
                    if (Test-Path $versionedPsd1) {
                        $meta = Get-ModuleMetadata -Path $versionedPsd1 -ForceSource 'published'
                        if ($meta) { $discovered.Add($meta); $null = $discoveredNames.Add($modName); Write-HubLog -Level Info -Message "  ✓ Discovered (published): $($meta.Name) v$($meta.Version)" }
                        break
                    }
                }
            }
        }
    }

    Write-HubLog -Level Info -Message "Scan complete: $($discovered.Count) module(s) found"
    if ($discovered.Count -eq 0) { return @() }
    return @($discovered)
}
