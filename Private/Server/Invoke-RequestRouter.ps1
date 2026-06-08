function Invoke-RequestRouter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $request = $Context.Request; $method = $request.HttpMethod; $path = $request.Url.LocalPath; $query = $request.QueryString
    Write-HubLog -Level Debug -Message "$method $path"

    if ($method -eq 'OPTIONS') {
        $Context.Response.StatusCode = 204
        $Context.Response.Headers.Add('Allow', 'GET, POST, DELETE, OPTIONS')
        $Context.Response.OutputStream.Close(); return
    }

    try {
        switch -Regex ($path) {
            # ── Static files ──
            '^/$' { Write-StaticFile -Context $Context -FilePath 'index.html' }
            '^/(css|js|img)/.+' { Write-StaticFile -Context $Context -FilePath $path.TrimStart('/') }
            '^/favicon\.ico$' { Write-StaticFile -Context $Context -FilePath 'img/favicon.ico' }

            # ── Modules ──
            '^/api/modules$' { Get-PortalModuleList -Context $Context }
            '^/api/modules/([^/]+)/commands$' { Get-PortalModuleCommands -Context $Context -ModuleName ([System.Uri]::UnescapeDataString($Matches[1])) }

            # ── Commands ──
            '^/api/commands/([^/]+)/([^/]+)/params$' { Get-PortalCommandParams -Context $Context -ModuleName ([System.Uri]::UnescapeDataString($Matches[1])) -CommandName ([System.Uri]::UnescapeDataString($Matches[2])) }
            '^/api/commands$' { Get-PortalCommandSearch -Context $Context -Query $query }

            # ── Execute ──
            '^/api/execute$' { Invoke-PortalCommand -Context $Context }

            # ── Background jobs ──
            '^/api/jobs/([a-f0-9]+)$' { Get-PortalJobStatus -Context $Context -JobId $Matches[1] }

            # ── Health ──
            '^/api/health$' { Get-PortalHealth -Context $Context }

            # ── Registry scan ──
            '^/api/registry/scan$' { Invoke-PortalRegistryScan -Context $Context }

            # ── Scan roots management ──
            '^/api/settings/scanroots$' {
                $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
                if ($method -eq 'POST') {
                    $reader = [System.IO.StreamReader]::new($request.InputStream); $bodyRaw = $reader.ReadToEnd(); $reader.Close()
                    $body = $bodyRaw | ConvertFrom-Json; $newPath = $body.path
                    if (-not $newPath) { Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Missing path field'; return }
                    $existingRoots = [System.Collections.Generic.List[string]]::new()
                    foreach ($r in $settings.scanRoots) { $existingRoots.Add($r) }
                    if ($existingRoots -contains $newPath) { Write-ErrorResponse -Context $Context -StatusCode 409 -Message 'Path already exists'; return }
                    $existingRoots.Add($newPath); $settings.scanRoots = @($existingRoots)
                    $settings | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:SettingsFile -Encoding utf8 -Force
                    Write-HubLog -Level Info -Message "Scan root added: $newPath"
                    Write-JsonResponse -Context $Context -Data @{ success = $true; scanRoots = @($settings.scanRoots) }
                } elseif ($method -eq 'DELETE') {
                    $reader = [System.IO.StreamReader]::new($request.InputStream); $bodyRaw = $reader.ReadToEnd(); $reader.Close()
                    $body = $bodyRaw | ConvertFrom-Json
                    $settings.scanRoots = @($settings.scanRoots | Where-Object { $_ -ne $body.path })
                    $settings | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:SettingsFile -Encoding utf8 -Force
                    Write-JsonResponse -Context $Context -Data @{ success = $true; scanRoots = @($settings.scanRoots) }
                } else {
                    Write-JsonResponse -Context $Context -Data @{ scanRoots = @($settings.scanRoots) }
                }
            }

            # ── Published modules toggle ──
            '^/api/settings/published$' {
                $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
                if ($method -eq 'POST') {
                    $reader = [System.IO.StreamReader]::new($request.InputStream); $bodyRaw = $reader.ReadToEnd(); $reader.Close()
                    $body = $bodyRaw | ConvertFrom-Json; $settings.scanPublishedModules = [bool]$body.enabled
                    $settings | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:SettingsFile -Encoding utf8 -Force
                    Write-JsonResponse -Context $Context -Data @{ success = $true; scanPublishedModules = $settings.scanPublishedModules }
                } else {
                    Write-JsonResponse -Context $Context -Data @{ scanPublishedModules = [bool]$settings.scanPublishedModules }
                }
            }

            # ── Settings (GET + POST) ──
            '^/api/settings$' {
                if ($method -eq 'POST') {
                    $reader = [System.IO.StreamReader]::new($request.InputStream); $bodyRaw = $reader.ReadToEnd(); $reader.Close()
                    try {
                        $newSettings = $bodyRaw | ConvertFrom-Json
                        $newSettings | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:SettingsFile -Encoding utf8 -Force
                        Write-JsonResponse -Context $Context -Data @{ success = $true }
                    } catch {
                        Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Invalid settings format'
                    }
                } else {
                    Get-PortalSettings -Context $Context
                }
            }

            # ── Favourites ──
            '^/api/favourites$' {
                if ($method -eq 'GET') {
                    $s = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
                    Write-JsonResponse -Context $Context -Data @{ favourites = @($s.favouriteCommands) }
                } elseif ($method -eq 'POST') {
                    $reader = [System.IO.StreamReader]::new($request.InputStream); $bodyRaw = $reader.ReadToEnd(); $reader.Close()
                    $body = $bodyRaw | ConvertFrom-Json; $s = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
                    $fav = @{ module = $body.module; command = $body.command; addedAt = (Get-Date).ToUniversalTime().ToString('o') }
                    $existing = @($s.favouriteCommands)
                    if (-not ($existing | Where-Object { $_.module -eq $fav.module -and $_.command -eq $fav.command })) {
                        $s.favouriteCommands = @($existing) + @($fav)
                        $s | ConvertTo-Json -Depth 10 | Out-File $script:SettingsFile -Encoding utf8 -Force
                    }
                    Write-JsonResponse -Context $Context -Data @{ success = $true }
                }
            }

            # ── Recent commands ──
            '^/api/recent$' {
                $s = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
                Write-JsonResponse -Context $Context -Data @{ recent = @($s.recentCommands) }
            }

            # ── Shutdown ──
            '^/api/shutdown$' {
                Write-HubLog -Level Info -Message 'Shutdown requested'
                Write-JsonResponse -Context $Context -Data @{ status = 'shutting down' }
                $script:StopListener = $true
            }

            # ── 404 ──
            default {
                Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Not found: $path"
            }
        }
    } catch {
        Write-HubLog -Level Error -Message "Router error on $path : $($_.Exception.Message)"
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message 'Internal error' -InternalDetail "Router error on ${path}: $($_.Exception.Message)"
    }
}
