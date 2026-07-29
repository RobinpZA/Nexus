# Test fixture standing in for a Graph-connected module. Get-MgContext and
# Disconnect-MgGraph are shadowed here so the connection endpoint can be exercised
# without a tenant.

$script:FakeContext = $null

function Connect-FakeGraph {
    <#
    .SYNOPSIS
        Pretends to sign in to Microsoft Graph.
    #>
    [CmdletBinding()]
    param(
        [string]$Account = 'tester@contoso.onmicrosoft.com',
        [ValidateSet('CurrentUser', 'Process')][string]$ContextScope = 'CurrentUser'
    )

    $script:FakeContext = [PSCustomObject]@{
        Account      = $Account
        TenantId     = '00000000-1111-2222-3333-444444444444'
        AuthType     = 'Delegated'
        ContextScope = $ContextScope
    }
    "connected as $Account"
}

function Get-MgContext {
    <#
    .SYNOPSIS
        Returns the fixture's fake Graph context.
    #>
    [CmdletBinding()]
    param()

    $script:FakeContext
}

function Disconnect-MgGraph {
    <#
    .SYNOPSIS
        Clears the fixture's fake Graph context.
    #>
    [CmdletBinding()]
    param()

    $script:FakeContext = $null
}
