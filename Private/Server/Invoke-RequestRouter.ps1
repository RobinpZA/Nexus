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

    if ($method -eq 'OPTIONS') {
        # No CORS headers: a cross-origin preflight must fail here.
        $Context.Response.StatusCode = 204
        $Context.Response.Headers.Add('Allow', 'GET, POST, DELETE, OPTIONS')
        $Context.Response.OutputStream.Close(); return
    }

    # SECURITY: CSRF guard — reject state-changing requests from other origins.
    if (-not (Test-RequestOrigin -Context $Context)) { return }

    try {
        foreach ($route in (Get-PortalRoute)) {
            if ($path -notmatch $route.Pattern) { continue }
            if (-not (Test-HttpMethod -Context $Context -Allowed $route.Methods)) { return }
            $routeArgs = @{ Context = $Context; Match = $Matches; Query = $query }
            & $route.Handler $routeArgs
            return
        }

        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Not found: $path"
    } catch {
        Write-HubLog -Level Error -Message "Router error on $path : $($_.Exception.Message)"
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message 'Internal error' -InternalDetail "Router error on ${path}: $($_.Exception.Message)"
    }
}

function Read-JsonRequestBody {
    <#
    .SYNOPSIS
        Reads and parses a JSON request body, returning $null when it is missing or invalid.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        $body = Read-JsonRequestBody -Context $Context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $reader = [System.IO.StreamReader]::new($Context.Request.InputStream)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Close() }

    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
