function Invoke-RequestRouter {
    <#
    .SYNOPSIS
        Dispatches a request to the first matching route.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Invoke-RequestRouter -Context $context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $request = $Context.Request
    $method  = $request.HttpMethod
    $path    = $request.Url.LocalPath
    $query   = $request.QueryString
    Write-HubLog -Level Debug -Message "$method $path"

    # Piggyback on every request (not just job polls) so a context recovers even if the
    # client that started an async job never comes back to check on it — see
    # Sync-BackgroundJob for why this isn't a dedicated background thread instead.
    Sync-BackgroundJob

    if ($method -eq 'OPTIONS') {
        # No CORS headers: a cross-origin preflight must fail here.
        $Context.Response.StatusCode = 204
        $Context.Response.Headers.Add('Allow', 'GET, POST, DELETE, OPTIONS')
        $Context.Response.OutputStream.Close(); return
    }

    # SECURITY: CSRF guard — reject state-changing requests from other origins.
    if (-not (Test-RequestOrigin -Context $Context)) { return }

    # SECURITY: Session token — see New-SessionToken. The URL Start-Nexus/Open-Nexus
    # opens carries ?token=; swap it for a cookie so it leaves the address bar.
    if ($method -eq 'GET' -and $path -eq '/' -and $query['token'] -and
        (Test-SessionToken -Expected $script:SessionToken -Header $query['token'])) {
        Write-SessionCookieRedirect -Context $Context
        return
    }

    # -like/-ne, not StartsWith: route patterns match case-insensitively, so a
    # case-sensitive check here would let /API/execute through unauthenticated.
    $isAuthenticated = Test-RequestSession -Context $Context
    if ($path -like '/api/*' -and $path -ne '/api/health' -and -not $isAuthenticated) {
        Write-HubLog -Level Warning -Message "Rejected unauthenticated $method $path" -Source 'Security'
        Write-ErrorResponse -Context $Context -StatusCode 401 -Message 'Session token missing or invalid. Run Open-Nexus to open an authorised session.'
        return
    }

    try {
        foreach ($route in (Get-PortalRoute)) {
            if ($path -notmatch $route.Pattern) { continue }
            if (-not (Test-HttpMethod -Context $Context -Allowed $route.Methods)) { return }
            $routeArgs = @{ Context = $Context; Match = $Matches; Query = $query; Authenticated = $isAuthenticated }
            & $route.Handler $routeArgs
            return
        }

        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Not found: $path"
    } catch {
        Write-HubLog -Level Error -Message "Router error on $path : $($_.Exception.Message)"
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message 'Internal error' -InternalDetail "Router error on ${path}: $($_.Exception.Message)"
    }
}

function Read-BoundedRequestBody {
    <#
    .SYNOPSIS
        Reads a stream into memory, stopping short and returning $null once MaxBytes
        would be exceeded.
    .DESCRIPTION
        Pure decision logic behind Read-JsonRequestBody — no HttpListener types, so the
        cap can be unit tested against a plain MemoryStream instead of a live socket.

        SECURITY: DeclaredLength (Content-Length) is client-supplied and can be absent
        entirely under chunked transfer encoding, so it is only ever a fast-path
        rejection. The streaming cap is what actually bounds memory use — an attacker
        who understates or omits Content-Length still hits it after MaxBytes bytes.
    .PARAMETER Stream
        The stream to read. Caller owns opening/closing it.
    .PARAMETER MaxBytes
        Largest body accepted.
    .PARAMETER DeclaredLength
        Content-Length as reported by the client, or -1 if unknown.
    .PARAMETER Source
        Label used in the security log line when a body is rejected (e.g. the request path).
    .EXAMPLE
        Read-BoundedRequestBody -Stream $stream -MaxBytes 1MB -DeclaredLength $request.ContentLength64 -Source $request.Url.LocalPath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$MaxBytes,
        [long]$DeclaredLength = -1,
        [string]$Source = ''
    )

    if ($DeclaredLength -gt $MaxBytes) {
        Write-HubLog -Level Error -Message "BLOCKED oversized request body on $Source (Content-Length: $DeclaredLength)" -Source 'Security'
        return $null
    }

    $chunk  = New-Object byte[] 65536
    $memory = [System.IO.MemoryStream]::new()
    while ($true) {
        $read = $Stream.Read($chunk, 0, $chunk.Length)
        if ($read -le 0) { break }
        if ($memory.Length + $read -gt $MaxBytes) {
            Write-HubLog -Level Error -Message "BLOCKED oversized request body on $Source (> $MaxBytes bytes)" -Source 'Security'
            return $null
        }
        $memory.Write($chunk, 0, $read)
    }

    return , $memory.ToArray()
}

function Read-JsonRequestBody {
    <#
    .SYNOPSIS
        Reads and parses a JSON request body, returning $null when it is missing,
        oversized, or invalid.
    .DESCRIPTION
        SECURITY: See Read-BoundedRequestBody — the read is capped at MaxBytes
        independently of Content-Length. Without this, the body would be buffered into
        memory in full before ConvertFrom-Json ever got a chance to reject it.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .PARAMETER MaxBytes
        Largest body accepted. Every payload this API expects is a small JSON object
        (command parameters, settings), so 1 MB is generous headroom, not a tuned limit.
    .EXAMPLE
        $body = Read-JsonRequestBody -Context $Context
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [long]$MaxBytes = 1MB
    )

    $request = $Context.Request
    $stream = $request.InputStream
    try {
        $bytes = Read-BoundedRequestBody -Stream $stream -MaxBytes $MaxBytes -DeclaredLength $request.ContentLength64 -Source $request.Url.LocalPath
    } finally {
        $stream.Close()
    }

    if ($null -eq $bytes -or $bytes.Length -eq 0) { return $null }
    $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
