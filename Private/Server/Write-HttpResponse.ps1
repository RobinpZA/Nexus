function Add-SecurityResponseHeader {
    <#
    .SYNOPSIS
        Adds the headers every Nexus response carries.
    .DESCRIPTION
        SECURITY: frame-ancestors (and CSP generally) only takes effect from a real HTTP
        header — the <meta http-equiv="Content-Security-Policy"> tag in index.html cannot
        enforce frame-ancestors; browsers silently ignore that directive there. Sent on
        every response, not just index.html, so a direct navigation to any Nexus URL
        can't be framed either. X-Frame-Options is the pre-CSP fallback for browsers that
        don't honour frame-ancestors.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Add-SecurityResponseHeader -Context $Context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $Context.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
    $Context.Response.Headers.Add('X-Frame-Options', 'DENY')
    $Context.Response.Headers.Add('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; form-action 'none'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'")
}

function Write-JsonResponse {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][object]$Data,
        [int]$StatusCode = 200
    )
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $buffer.Length
    # SECURITY: No CORS headers — same-origin only (localhost serves both API and portal).
    # Cross-origin writes are rejected up front by Test-RequestOrigin; CORS alone does not stop them.
    Add-SecurityResponseHeader -Context $Context
    $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Context.Response.OutputStream.Close()
}

function Write-StaticFile {
    <#
    .SYNOPSIS
        Serves a static file from Assets/portal. SECURITY: Canonicalizes path and validates
        the resolved path stays within the portal root to prevent directory traversal.
    #>
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$FilePath
    )

    # SECURITY: Resolve the full canonical path and verify it's under the portal root
    # The separator matters: without it a sibling folder such as "portal-backup" would pass.
    $portalRootFull = [System.IO.Path]::GetFullPath($script:PortalRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $requestedFull  = [System.IO.Path]::GetFullPath((Join-Path $script:PortalRoot $FilePath))

    if (-not $requestedFull.StartsWith($portalRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-HubLog -Level Error -Message "BLOCKED path traversal attempt: $FilePath -> $requestedFull" -Source 'Security'
        Write-ErrorResponse -Context $Context -StatusCode 403 -Message 'Forbidden'
        return
    }

    if (-not (Test-Path $requestedFull)) {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message 'Not found'
        return
    }

    $ext = [System.IO.Path]::GetExtension($requestedFull).ToLower()
    $contentType = switch ($ext) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.svg'  { 'image/svg+xml' }
        '.png'  { 'image/png' }
        '.ico'  { 'image/x-icon' }
        '.jpg'  { 'image/jpeg' }
        '.gif'  { 'image/gif' }
        '.woff' { 'font/woff' }
        '.woff2'{ 'font/woff2' }
        default { 'application/octet-stream' }
    }

    try {
        $buffer = [System.IO.File]::ReadAllBytes($requestedFull)
        $Context.Response.StatusCode = 200
        $Context.Response.ContentType = $contentType
        $Context.Response.ContentLength64 = $buffer.Length
        Add-SecurityResponseHeader -Context $Context
        if ($ext -ne '.html') { $Context.Response.Headers.Add('Cache-Control', 'public, max-age=3600') }
        else { $Context.Response.Headers.Add('Cache-Control', 'no-cache') }
        $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $Context.Response.OutputStream.Close()
    } catch {
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message 'Internal error'
    }
}

function Write-ErrorResponse {
    <#
    .SYNOPSIS
        Writes a generic error JSON response. SECURITY: Does NOT expose internal exception
        details to the client. Details are logged server-side only.
    #>
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [int]$StatusCode = 500,
        [string]$Message = 'Internal Server Error',
        [string]$InternalDetail
    )

    # Log the internal detail server-side only
    if ($InternalDetail) {
        Write-HubLog -Level Error -Message "HTTP $StatusCode — $InternalDetail"
    }

    # Generic message to client — no stack traces, no internal paths
    $safeMessage = switch ($StatusCode) {
        400 { $Message }   # Bad request messages are intentional (e.g. "Missing field: module")
        401 { $Message }   # Tells the user how to get a session; reveals nothing
        403 { 'Forbidden' }
        404 { $Message }   # "Not found" is safe
        405 { $Message }   # Method not allowed is safe
        409 { $Message }   # Conflict messages are intentional
        default { 'An error occurred. Check the server log for details.' }
    }

    $data = @{ error = $true; statusCode = $StatusCode; message = $safeMessage }
    Write-JsonResponse -Context $Context -Data $data -StatusCode $StatusCode
}
