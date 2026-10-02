function New-SessionToken {
    <#
    .SYNOPSIS
        Generates a random per-session API token.
    .DESCRIPTION
        SECURITY: The listener is reachable by every process on the machine, including
        other users' processes. The origin check stops web pages; this token stops local
        callers that never received it. It reaches the browser only through the URL that
        Start-Nexus/Open-Nexus opens, never through a page any caller can fetch.
    .EXAMPLE
        $script:SessionToken = New-SessionToken
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
}

function Get-SessionCookieName {
    <#
    .SYNOPSIS
        Returns the session cookie name for a port.
    .DESCRIPTION
        Cookies are not isolated by port, so two Nexus instances on 127.0.0.1 would
        overwrite each other's cookie without the port in the name.
    .PARAMETER Port
        The port the listener is bound to.
    .EXAMPLE
        Get-SessionCookieName -Port 8090
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Port)

    return "nexus_session_$Port"
}

function Test-SessionToken {
    <#
    .SYNOPSIS
        Decides whether a request carries the session token, from header and cookie values.
    .DESCRIPTION
        Pure decision function behind Test-RequestSession — no HttpListener types, so the
        rules can be unit tested directly. Fails closed when no session token is set.
        Compares in constant time so the token can't be recovered by timing responses.
    .PARAMETER Expected
        The current session token.
    .PARAMETER Header
        The X-Nexus-Token header value, if any (CLI clients).
    .PARAMETER Cookie
        The session cookie value, if any (the portal).
    .EXAMPLE
        Test-SessionToken -Expected $token -Cookie $cookieValue
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Expected,
        [AllowNull()][AllowEmptyString()][string]$Header,
        [AllowNull()][AllowEmptyString()][string]$Cookie
    )

    if ([string]::IsNullOrEmpty($Expected)) { return $false }

    $expectedBytes = [System.Text.Encoding]::UTF8.GetBytes($Expected)
    foreach ($candidate in @($Header, $Cookie)) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        $candidateBytes = [System.Text.Encoding]::UTF8.GetBytes($candidate)
        if ([System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expectedBytes, $candidateBytes)) {
            return $true
        }
    }
    return $false
}

function Test-RequestSession {
    <#
    .SYNOPSIS
        Returns whether a request carries the current session token, via header or cookie.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        if (-not (Test-RequestSession -Context $Context)) { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $request = $Context.Request
    $cookie  = $request.Cookies[(Get-SessionCookieName -Port $request.Url.Port)]

    return Test-SessionToken -Expected $script:SessionToken `
        -Header $request.Headers['X-Nexus-Token'] `
        -Cookie $(if ($cookie) { $cookie.Value })
}

function Write-SessionCookieRedirect {
    <#
    .SYNOPSIS
        Exchanges a ?token= URL for an HttpOnly session cookie and redirects to /.
    .DESCRIPTION
        The redirect takes the token out of the address bar. HttpOnly keeps it from
        scripts on other localhost ports (cookies ignore ports); SameSite=Strict keeps
        it off cross-site requests.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Write-SessionCookieRedirect -Context $Context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $name = Get-SessionCookieName -Port $Context.Request.Url.Port
    $Context.Response.Headers.Add('Set-Cookie', "$name=$($script:SessionToken); Path=/; HttpOnly; SameSite=Strict")
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    Add-SecurityResponseHeader -Context $Context
    $Context.Response.StatusCode = 302
    $Context.Response.RedirectLocation = '/'
    $Context.Response.OutputStream.Close()
}
