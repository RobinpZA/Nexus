function Get-ContextConnectionState {
    <#
    .SYNOPSIS
        Reports which services a module's context is signed in to.
    .DESCRIPTION
        Only inspects a context that already exists. Creating one just to answer "are you
        connected?" would spawn a worker process per module on every page view, and a
        module with no context by definition has no session.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .PARAMETER Action
        'status' to report, 'disconnect' to sign out first and then report.
    .EXAMPLE
        Get-ContextConnectionState -ModuleEntry $mod
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [ValidateSet('status', 'disconnect')][string]$Action = 'status'
    )

    $name = $ModuleEntry.name

    if (-not $script:ModuleRunspaces -or -not $script:ModuleRunspaces.ContainsKey($name)) {
        return [PSCustomObject]@{
            status = 'ok'
            message = $null
            data = [PSCustomObject]@{ active = $false; providers = @() }
        }
    }

    $envelope = Invoke-ContextMetadataRequest -ModuleEntry $ModuleEntry -Mode 'connection' `
        -Script (Get-ConnectionStateScript) -Argument $Action

    if ($envelope.status -ne 'ok') { return $envelope }

    $providers = @()
    if ($envelope.data -and $envelope.data.providers) {
        $providers = @($envelope.data.providers | ForEach-Object {
            [PSCustomObject]@{
                name = $_.name; connected = [bool]$_.connected; account = $_.account
                tenant = $_.tenant; detail = $_.detail; shared = [bool]$_.shared
            }
        })
    }

    return [PSCustomObject]@{
        status = 'ok'
        message = $null
        data = [PSCustomObject]@{ active = $true; providers = $providers }
    }
}
