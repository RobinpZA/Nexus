function Get-ConnectionStateScript {
    <#
    .SYNOPSIS
        Returns the script that reports (or drops) a context's service sign-ins.
    .DESCRIPTION
        Runs inside the module's own runspace or worker process. Takes 'status' or
        'disconnect' as its argument.

        Worth knowing: Microsoft Graph caches delegated tokens under the user's profile
        (%LOCALAPPDATA%\.IdentityService) unless the module connects with
        -ContextScope Process, so a sign-in made by one module can be picked up silently
        by another — including by processes Nexus did not start. Nexus reports what each
        context sees; it cannot un-share that cache.
    .EXAMPLE
        $ps.AddScript((Get-ConnectionStateScript)).AddArgument('status')
    #>
    [CmdletBinding()]
    param()

    return @'
param($Action)

# Providers are found through the LOADED module table only. Get-Command would run module
# discovery and auto-load Microsoft.Graph.Authentication into a context that never used
# it — measured at 8.6s and, worse, it would report a Graph provider for modules that
# have nothing to do with Graph. A module that was never loaded has no session anyway.
$loaded = @(Get-Module)

$providers = @()

# ── Microsoft Graph ──
$graph = $loaded | Where-Object { $_.ExportedCommands.ContainsKey('Get-MgContext') } | Select-Object -First 1
if ($graph) {
    if ($Action -eq 'disconnect' -and $graph.ExportedCommands.ContainsKey('Disconnect-MgGraph')) {
        try { & $graph.ExportedCommands['Disconnect-MgGraph'] | Out-Null } catch { }
    }

    $context = $null
    try { $context = & $graph.ExportedCommands['Get-MgContext'] } catch { }

    $providers += [PSCustomObject]@{
        name      = 'Microsoft Graph'
        connected = [bool]$context
        account   = if ($context) { $context.Account } else { $null }
        tenant    = if ($context) { $context.TenantId } else { $null }
        detail    = if ($context) { "$($context.AuthType) · $($context.ContextScope)" } else { $null }
        shared    = if ($context) { "$($context.ContextScope)" -ne 'Process' } else { $false }
    }
}

# ── Exchange Online ──
$exchange = $loaded | Where-Object { $_.ExportedCommands.ContainsKey('Get-ConnectionInformation') } | Select-Object -First 1
if ($exchange) {
    if ($Action -eq 'disconnect' -and $exchange.ExportedCommands.ContainsKey('Disconnect-ExchangeOnline')) {
        try { & $exchange.ExportedCommands['Disconnect-ExchangeOnline'] -Confirm:$false | Out-Null } catch { }
    }

    $session = $null
    try { $session = @(& $exchange.ExportedCommands['Get-ConnectionInformation'])[0] } catch { }

    $providers += [PSCustomObject]@{
        name      = 'Exchange Online'
        connected = [bool]$session
        account   = if ($session) { $session.UserPrincipalName } else { $null }
        tenant    = if ($session) { $session.TenantId } else { $null }
        detail    = if ($session) { "$($session.State)" } else { $null }
        shared    = $false
    }
}

[PSCustomObject]@{ providers = @($providers) }
'@
}
