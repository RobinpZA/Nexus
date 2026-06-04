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

    # Ensure module is imported
    $imported = Import-RegisteredModule -ModuleEntry $mod
    if (-not $imported) {
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message "Failed to import module: $ModuleName"
        return
    }

    $paramInfo = Get-CommandParameters -CommandName $CommandName
    if (-not $paramInfo) {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Command not found: $CommandName"
        return
    }

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
