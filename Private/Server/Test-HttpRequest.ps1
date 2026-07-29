function Test-RequestOrigin {
    <#
    .SYNOPSIS
        SECURITY: Rejects cross-site requests on state-changing HTTP methods (CSRF guard).
    .DESCRIPTION
        The listener is bound to 127.0.0.1, but any web page the user visits can still
        reach it. A cross-origin form POST with enctype="text/plain" is a "simple request",
        so it is delivered without a preflight and the absence of CORS headers does NOT
        stop it — CORS only blocks the attacker from reading the response.

        Rules for POST/PUT/PATCH/DELETE:
          - Origin present  -> must match the origin this request was served on.
          - Referer present -> must be under the same origin.
          - Neither present -> only allowed for application/json bodies. Browsers cannot
            send that cross-origin without a successful preflight, and Nexus never grants
            one, so this keeps CLI clients (curl, Invoke-RestMethod) working.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        if (-not (Test-RequestOrigin -Context $Context)) { return }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context
    )

    $request = $Context.Request

    $allowed = Test-SameOriginRequest `
        -Method $request.HttpMethod `
        -ExpectedOrigin $request.Url.GetLeftPart([System.UriPartial]::Authority) `
        -Origin $request.Headers['Origin'] `
        -Referer $request.Headers['Referer'] `
        -ContentType $request.ContentType

    if ($allowed) { return $true }

    Write-HubLog -Level Error -Message "BLOCKED cross-site $($request.HttpMethod) $($request.Url.LocalPath) (Origin: '$($request.Headers['Origin'])', Referer: '$($request.Headers['Referer'])', Content-Type: '$($request.ContentType)')" -Source 'Security'
    Write-ErrorResponse -Context $Context -StatusCode 403 -Message 'Forbidden'
    return $false
}

function Test-SameOriginRequest {
    <#
    .SYNOPSIS
        Decides whether a request may change state, from its method and headers alone.
    .DESCRIPTION
        Pure decision function behind Test-RequestOrigin — no HttpListener types, so the
        rules can be unit tested directly.
    .PARAMETER Method
        The HTTP method.
    .PARAMETER ExpectedOrigin
        The origin the request was served on, e.g. http://127.0.0.1:8090.
    .PARAMETER Origin
        The request's Origin header, if any.
    .PARAMETER Referer
        The request's Referer header, if any.
    .PARAMETER ContentType
        The request's Content-Type header, if any.
    .EXAMPLE
        Test-SameOriginRequest -Method POST -ExpectedOrigin 'http://127.0.0.1:8090' -Origin 'http://evil.test'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$ExpectedOrigin,
        [AllowNull()][AllowEmptyString()][string]$Origin,
        [AllowNull()][AllowEmptyString()][string]$Referer,
        [AllowNull()][AllowEmptyString()][string]$ContentType
    )

    # Safe methods cannot change state.
    if ($Method -in @('GET', 'HEAD', 'OPTIONS')) { return $true }

    if ($Origin) {
        return ($Origin -eq $ExpectedOrigin)
    }

    if ($Referer) {
        return ($Referer -eq $ExpectedOrigin -or
                $Referer.StartsWith("$ExpectedOrigin/", [System.StringComparison]::OrdinalIgnoreCase))
    }

    # No Origin/Referer: only a JSON body is accepted. A browser cannot send that
    # cross-origin without a preflight, which Nexus never approves; CLI clients can.
    return ([bool]$ContentType -and $ContentType.Trim().StartsWith('application/json', [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-HttpMethod {
    <#
    .SYNOPSIS
        Verifies the request method is allowed for a route, writing 405 when it is not.
    .DESCRIPTION
        Without this, a route that only handles some methods falls through the router
        without writing a response, leaving the client hanging until it times out.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .PARAMETER Allowed
        The methods this route accepts.
    .EXAMPLE
        if (-not (Test-HttpMethod -Context $Context -Allowed 'POST')) { return }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string[]]$Allowed
    )

    $method = $Context.Request.HttpMethod
    if ($method -in $Allowed) { return $true }

    $Context.Response.Headers.Add('Allow', ($Allowed -join ', '))
    Write-ErrorResponse -Context $Context -StatusCode 405 -Message "Method not allowed: $method"
    return $false
}
