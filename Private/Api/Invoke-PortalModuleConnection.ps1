function Invoke-PortalModuleConnection {
    <#
    .SYNOPSIS
        API handler: GET/DELETE /api/modules/{name}/connection
    .DESCRIPTION
        GET reports which services the module's live context is signed in to; DELETE signs
        it out. Reported per module because a sign-in is not necessarily private to one:
        Microsoft Graph persists delegated tokens under the user's profile unless a module
        connects with -ContextScope Process, so another module can pick the same sign-in up
        silently. The 'shared' flag marks exactly that case.
    .PARAMETER Context
        The HttpListenerContext for the current request.
    .EXAMPLE
        Invoke-PortalModuleConnection -Context $Context
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$ModuleName
    )

    $registry = Read-ModuleRegistry
    $module = $registry.modules | Where-Object { $_.name -eq $ModuleName }

    if (-not $module) {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Module not found: $ModuleName"
        return
    }

    $action = if ($Context.Request.HttpMethod -eq 'DELETE') { 'disconnect' } else { 'status' }
    $state = Get-ContextConnectionState -ModuleEntry $module -Action $action

    if ($state.status -eq 'busy') {
        Write-ErrorResponse -Context $Context -StatusCode 409 -Message $state.message
        return
    }
    if ($state.status -ne 'ok') {
        Write-HubLog -Level Warning -Message "Connection state failed for $ModuleName : $($state.message)"
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message 'Could not read connection state'
        return
    }

    if ($action -eq 'disconnect') {
        Write-HubLog -Level Info -Message "Sign-out requested for $ModuleName" -Source $ModuleName
    }

    Write-JsonResponse -Context $Context -Data @{
        module    = $ModuleName
        active    = [bool]$state.data.active
        providers = @($state.data.providers)
    }
}
