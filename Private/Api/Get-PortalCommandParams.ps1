function Get-PortalCommandParams {
    <#
    .SYNOPSIS
        API handler: GET /api/commands/{module}/{cmd}/params — returns parameter metadata.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext]$Context,

        [Parameter(Mandatory)]
        [string]$ModuleName,

        [Parameter(Mandatory)]
        [string]$CommandName
    )

    $registry = Read-ModuleRegistry
    $mod = $registry.modules | Where-Object { $_.name -eq $ModuleName }

    if (-not $mod) {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Module not found: $ModuleName"
        return
    }

    # Read the metadata inside the module's own context — importing it here would load
    # its dependencies (Graph, EXO, Teams) into the listener process.
    $info = Get-ContextCommandParameters -ModuleEntry $mod -CommandName $CommandName

    if ($info.status -eq 'busy') {
        Write-ErrorResponse -Context $Context -StatusCode 409 -Message $info.message
        return
    }
    if ($info.status -ne 'ok' -or -not $info.data) {
        Write-HubLog -Level Warning -Message "Metadata failed for $ModuleName/$CommandName : $($info.message)"
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Command not found: $CommandName"
        return
    }

    $paramInfo = $info.data

    $data = @{
        command     = $paramInfo.command
        module      = $ModuleName
        synopsis    = $paramInfo.synopsis
        description = $paramInfo.description
        parameters  = @($paramInfo.parameters | ForEach-Object {
            @{
                name         = $_.name
                type         = $_.type
                mandatory    = $_.mandatory
                position     = $_.position
                helpMessage  = $_.helpMessage
                validateSet  = $_.validateSet
                defaultValue = $_.defaultValue
                aliases      = @($_.aliases)
            }
        })
    }

    Write-JsonResponse -Context $Context -Data $data
}
