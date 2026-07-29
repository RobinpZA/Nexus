function Get-PortalRoute {
    <#
    .SYNOPSIS
        Returns the portal's route table, in match order.
    .DESCRIPTION
        Replaces a `switch -Regex`, where every branch had to stay anchored or two
        handlers would run and write two responses into one stream. Each route declares
        the methods it accepts, so an unhandled combination answers 405 instead of
        leaving the request open.

        Each handler takes one argument: a hashtable with Context, Match and Query.
    .EXAMPLE
        foreach ($route in Get-PortalRoute) { if ($path -match $route.Pattern) { ... } }
    #>
    [CmdletBinding()]
    param()

    return @(
        # ── Static files ──
        @{ Pattern = '^/$'; Methods = @('GET')
           Handler = { param($R) Write-StaticFile -Context $R.Context -FilePath 'index.html' } }

        @{ Pattern = '^/(css|js|img)/.+'; Methods = @('GET')
           Handler = { param($R) Write-StaticFile -Context $R.Context -FilePath $R.Context.Request.Url.LocalPath.TrimStart('/') } }

        @{ Pattern = '^/favicon\.ico$'; Methods = @('GET')
           Handler = { param($R) Write-StaticFile -Context $R.Context -FilePath 'img/favicon.ico' } }

        # ── Modules ──
        @{ Pattern = '^/api/modules$'; Methods = @('GET')
           Handler = { param($R) Get-PortalModuleList -Context $R.Context } }

        @{ Pattern = '^/api/modules/([^/]+)/commands$'; Methods = @('GET')
           Handler = { param($R) Get-PortalModuleCommands -Context $R.Context -ModuleName ([System.Uri]::UnescapeDataString($R.Match[1])) } }

        @{ Pattern = '^/api/modules/([^/]+)/connection$'; Methods = @('GET', 'DELETE')
           Handler = { param($R) Invoke-PortalModuleConnection -Context $R.Context -ModuleName ([System.Uri]::UnescapeDataString($R.Match[1])) } }

        # ── Commands ──
        @{ Pattern = '^/api/commands/([^/]+)/([^/]+)/params$'; Methods = @('GET')
           Handler = { param($R) Get-PortalCommandParams -Context $R.Context -ModuleName ([System.Uri]::UnescapeDataString($R.Match[1])) -CommandName ([System.Uri]::UnescapeDataString($R.Match[2])) } }

        @{ Pattern = '^/api/commands$'; Methods = @('GET')
           Handler = { param($R) Get-PortalCommandSearch -Context $R.Context -Query $R.Query } }

        # ── Execute ──
        @{ Pattern = '^/api/execute$'; Methods = @('POST')
           Handler = { param($R) Invoke-PortalCommand -Context $R.Context } }

        # ── Background jobs ──
        @{ Pattern = '^/api/jobs/([a-f0-9]+)$'; Methods = @('GET')
           Handler = { param($R) Get-PortalJobStatus -Context $R.Context -JobId $R.Match[1] } }

        # ── Health ──
        @{ Pattern = '^/api/health$'; Methods = @('GET')
           Handler = { param($R) Get-PortalHealth -Context $R.Context } }

        # ── Registry scan ──
        @{ Pattern = '^/api/registry/scan$'; Methods = @('POST')
           Handler = { param($R) Invoke-PortalRegistryScan -Context $R.Context } }

        # ── Settings ──
        @{ Pattern = '^/api/settings/scanroots$'; Methods = @('GET', 'POST', 'DELETE')
           Handler = { param($R) Invoke-PortalScanRoot -Context $R.Context } }

        @{ Pattern = '^/api/settings/published$'; Methods = @('GET', 'POST')
           Handler = { param($R) Invoke-PortalPublishedToggle -Context $R.Context } }

        @{ Pattern = '^/api/settings$'; Methods = @('GET', 'POST')
           Handler = { param($R) Invoke-PortalSettings -Context $R.Context } }

        # ── Favourites and history ──
        @{ Pattern = '^/api/favourites$'; Methods = @('GET', 'POST', 'DELETE')
           Handler = { param($R) Invoke-PortalFavourite -Context $R.Context } }

        @{ Pattern = '^/api/recent$'; Methods = @('GET')
           Handler = { param($R) Get-PortalRecent -Context $R.Context } }

        # ── Shutdown ──
        @{ Pattern = '^/api/shutdown$'; Methods = @('POST')
           Handler = { param($R) Invoke-PortalShutdown -Context $R.Context } }
    )
}
