function Get-ContextCommandParameters {
    <#
    .SYNOPSIS
        Reads a command's parameter metadata from inside the module's own context.
    .DESCRIPTION
        Returns a status envelope: 'ok' with the metadata, 'busy' when the context is
        running a command, or 'error' with a message.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .PARAMETER CommandName
        The command to describe.
    .EXAMPLE
        $info = Get-ContextCommandParameters -ModuleEntry $mod -CommandName 'Get-Thing'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [Parameter(Mandatory)][string]$CommandName
    )

    return Invoke-ContextMetadataRequest -ModuleEntry $ModuleEntry -Mode 'params' `
        -Script (Get-CommandMetadataScript) -Argument $CommandName
}

function Get-ContextCommandSynopsis {
    <#
    .SYNOPSIS
        Reads Get-Help synopses for a set of commands from inside the module's own context.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .PARAMETER CommandNames
        The commands to describe.
    .EXAMPLE
        $info = Get-ContextCommandSynopsis -ModuleEntry $mod -CommandNames @('Get-Thing')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [Parameter(Mandatory)][string[]]$CommandNames
    )

    return Invoke-ContextMetadataRequest -ModuleEntry $ModuleEntry -Mode 'synopsis' `
        -Script (Get-CommandSynopsisScript) -Argument $CommandNames
}

function Invoke-ContextMetadataRequest {
    <#
    .SYNOPSIS
        Runs a fixed reflection script in a module's runspace or child process.
    .DESCRIPTION
        Metadata is read where the module is loaded. Reading it in the Nexus process
        would import the module's dependencies into the listener's own session.

        Process contexts serve these requests over the same single command channel, so
        a context already running a command answers 'busy' rather than queueing.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .PARAMETER Mode
        The worker protocol mode: 'params', 'synopsis' or 'connection'.
    .PARAMETER Script
        The reflection script to run in runspace mode.
    .PARAMETER Argument
        The single argument passed to the script.
    .PARAMETER TimeoutSeconds
        How long to wait for a child process to answer.
    .EXAMPLE
        Invoke-ContextMetadataRequest -ModuleEntry $mod -Mode 'params' -Script $s -Argument 'Get-Thing'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [Parameter(Mandatory)][ValidateSet('params', 'synopsis', 'connection')][string]$Mode,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][object]$Argument,
        [int]$TimeoutSeconds = 45
    )

    $context = Get-ModuleRunspace -ModuleEntry $ModuleEntry
    if (-not $context) {
        return [PSCustomObject]@{ status = 'error'; message = "Failed to create context for: $($ModuleEntry.name)"; data = $null }
    }

    $activeJobId = Get-ActiveContextJob -ContextEntry $context
    if ($activeJobId) {
        return [PSCustomObject]@{ status = 'busy'; message = "Module '$($ModuleEntry.name)' is running a command (jobId: $activeJobId)"; data = $null }
    }

    if ($context.Mode -eq 'process') {
        return Invoke-ProcessMetadataRequest -ProcessEntry $context -ModuleEntry $ModuleEntry -Mode $Mode -Argument $Argument -TimeoutSeconds $TimeoutSeconds
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $context.Runspace
    try {
        $null = $ps.AddScript($Script).AddArgument($Argument)
        $results = $ps.Invoke()
        if ($ps.Streams.Error.Count -gt 0) {
            return [PSCustomObject]@{ status = 'error'; message = $ps.Streams.Error[0].ToString(); data = $null }
        }
        $context.LastUsed = Get-Date
        return [PSCustomObject]@{ status = 'ok'; message = $null; data = @($results)[0] }
    } catch {
        $message = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        return [PSCustomObject]@{ status = 'error'; message = $message; data = $null }
    } finally {
        $ps.Dispose()
    }
}

function Invoke-ProcessMetadataRequest {
    <#
    .SYNOPSIS
        Asks a child process for command metadata over its command channel.
    .PARAMETER ProcessEntry
        The process context entry.
    .PARAMETER ModuleEntry
        The registry entry for the module.
    .PARAMETER Mode
        The worker protocol mode: 'params' or 'synopsis'.
    .PARAMETER Argument
        The command name, or list of command names.
    .PARAMETER TimeoutSeconds
        How long to wait for the response file.
    .EXAMPLE
        Invoke-ProcessMetadataRequest -ProcessEntry $ctx -ModuleEntry $mod -Mode 'params' -Argument 'Get-Thing'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ProcessEntry,
        [Parameter(Mandatory)][object]$ModuleEntry,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][object]$Argument,
        [int]$TimeoutSeconds = 45
    )

    $ProcessEntry = Send-ProcessRequest -ProcessEntry $ProcessEntry -ModuleEntry $ModuleEntry -Request @{
        mode = $Mode; command = $Argument
    }
    if (-not $ProcessEntry) {
        return [PSCustomObject]@{ status = 'error'; message = 'Failed to restart process'; data = $null }
    }

    $timeout = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $timeout) {
        if ($ProcessEntry.Process.HasExited) {
            return [PSCustomObject]@{ status = 'error'; message = 'Process exited unexpectedly'; data = $null }
        }

        $response = Receive-ProcessResponse -ProcessEntry $ProcessEntry
        if ($response) {
            $ProcessEntry.LastUsed = Get-Date
            if (-not $response.success) {
                $message = if ($response.output) { @($response.output)[0].message } else { 'Metadata request failed' }
                return [PSCustomObject]@{ status = 'error'; message = $message; data = $null }
            }
            return [PSCustomObject]@{ status = 'ok'; message = $null; data = $response.metadata }
        }

        Start-Sleep -Milliseconds 150
    }

    return [PSCustomObject]@{ status = 'error'; message = 'No response from process (timeout)'; data = $null }
}
