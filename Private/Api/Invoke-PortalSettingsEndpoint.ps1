function Invoke-PortalSettings {
    <#
    .SYNOPSIS
        API handler: GET/POST /api/settings
    .DESCRIPTION
        POST merges known keys only — see Merge-HubSettings. A partial or malformed body
        must never replace the file wholesale.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Invoke-PortalSettings -Context $Context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    if ($Context.Request.HttpMethod -ne 'POST') {
        Get-PortalSettings -Context $Context
        return
    }

    $body = Read-JsonRequestBody -Context $Context
    if ($null -eq $body) { Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Invalid settings format'; return }

    try {
        $merged = Merge-HubSettings -Current (Read-HubSettings) -Incoming $body
        Save-HubSettings -Settings $merged
        if ($merged.logLevel) { $script:LogLevel = [string]$merged.logLevel }
        Write-JsonResponse -Context $Context -Data @{ success = $true }
    } catch {
        Write-ErrorResponse -Context $Context -StatusCode 400 -Message $_.Exception.Message
    }
}

function Invoke-PortalScanRoot {
    <#
    .SYNOPSIS
        API handler: GET/POST/DELETE /api/settings/scanroots
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Invoke-PortalScanRoot -Context $Context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $method   = $Context.Request.HttpMethod
    $settings = Read-HubSettings

    if ($method -eq 'GET') {
        Write-JsonResponse -Context $Context -Data @{ scanRoots = @($settings.scanRoots) }
        return
    }

    $body = Read-JsonRequestBody -Context $Context
    if ($null -eq $body) { Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Invalid JSON body'; return }
    if (-not $body.path) { Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Missing path field'; return }

    $path = [string]$body.path

    if ($method -eq 'POST') {
        $roots = [System.Collections.Generic.List[string]]::new()
        foreach ($root in $settings.scanRoots) { $roots.Add($root) }
        if ($roots -contains $path) { Write-ErrorResponse -Context $Context -StatusCode 409 -Message 'Path already exists'; return }

        $roots.Add($path)
        $settings.scanRoots = @($roots)
        Save-HubSettings -Settings $settings
        Write-HubLog -Level Info -Message "Scan root added: $path"
    } else {
        $settings.scanRoots = @($settings.scanRoots | Where-Object { $_ -ne $path })
        Save-HubSettings -Settings $settings
        Write-HubLog -Level Info -Message "Scan root removed: $path"
    }

    Write-JsonResponse -Context $Context -Data @{ success = $true; scanRoots = @($settings.scanRoots) }
}

function Invoke-PortalPublishedToggle {
    <#
    .SYNOPSIS
        API handler: GET/POST /api/settings/published
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Invoke-PortalPublishedToggle -Context $Context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $settings = Read-HubSettings

    if ($Context.Request.HttpMethod -ne 'POST') {
        Write-JsonResponse -Context $Context -Data @{ scanPublishedModules = [bool]$settings.scanPublishedModules }
        return
    }

    $body = Read-JsonRequestBody -Context $Context
    if ($null -eq $body) { Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Invalid JSON body'; return }

    try { $settings.scanPublishedModules = ConvertTo-HubBoolean -Value $body.enabled -Key 'enabled' }
    catch { Write-ErrorResponse -Context $Context -StatusCode 400 -Message $_.Exception.Message; return }

    Save-HubSettings -Settings $settings
    Write-JsonResponse -Context $Context -Data @{ success = $true; scanPublishedModules = $settings.scanPublishedModules }
}

function Invoke-PortalFavourite {
    <#
    .SYNOPSIS
        API handler: GET/POST/DELETE /api/favourites
    .DESCRIPTION
        DELETE was missing, so a favourite could be added but never removed.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Invoke-PortalFavourite -Context $Context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $method   = $Context.Request.HttpMethod
    $settings = Read-HubSettings

    if ($method -eq 'GET') {
        Write-JsonResponse -Context $Context -Data @{ favourites = @($settings.favouriteCommands) }
        return
    }

    $body = Read-JsonRequestBody -Context $Context
    if ($null -eq $body) { Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Invalid JSON body'; return }
    if (-not $body.module -or -not $body.command) {
        Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Missing required fields: module, command'
        return
    }

    $module   = [string]$body.module
    $command  = [string]$body.command
    $existing = @($settings.favouriteCommands)

    if ($method -eq 'POST') {
        if (-not ($existing | Where-Object { $_.module -eq $module -and $_.command -eq $command })) {
            $favourite = @{ module = $module; command = $command; addedAt = (Get-Date).ToUniversalTime().ToString('o') }
            $settings.favouriteCommands = @($existing) + @($favourite)
            Save-HubSettings -Settings $settings
        }
    } else {
        $settings.favouriteCommands = @($existing | Where-Object { -not ($_.module -eq $module -and $_.command -eq $command) })
        Save-HubSettings -Settings $settings
    }

    Write-JsonResponse -Context $Context -Data @{ success = $true; favourites = @($settings.favouriteCommands) }
}

function Get-PortalRecent {
    <#
    .SYNOPSIS
        API handler: GET /api/recent
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Get-PortalRecent -Context $Context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $settings = Read-HubSettings
    Write-JsonResponse -Context $Context -Data @{ recent = @($settings.recentCommands) }
}

function Invoke-PortalShutdown {
    <#
    .SYNOPSIS
        API handler: POST /api/shutdown
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Invoke-PortalShutdown -Context $Context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    Write-HubLog -Level Info -Message 'Shutdown requested'
    Write-JsonResponse -Context $Context -Data @{ status = 'shutting down' }
    $script:StopListener = $true
}
