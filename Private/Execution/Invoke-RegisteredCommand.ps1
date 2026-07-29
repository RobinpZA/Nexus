function Invoke-RegisteredCommand {
    <#
    .SYNOPSIS
        Imports the parent module if needed, then invokes the specified command.
        SECURITY: Validates command is exported by the target module before execution.
        Uses module-scoped invocation to prevent global command resolution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [Parameter(Mandatory)][string]$CommandName,
        [hashtable]$Parameters = @{}
    )

    $startTime = Get-Date

    # ── 1. Import module ──
    $imported = Import-RegisteredModule -ModuleEntry $ModuleEntry
    if (-not $imported) {
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = "Failed to import module: $($ModuleEntry.name)" })
        }
    }

    # ── 2. SECURITY: Validate command belongs to this module ──
    # Read the module's declared exports from its manifest (source of truth)
    $allowedCommands = @()
    if (Test-Path $ModuleEntry.path) {
        try {
            $manifestData = Import-PowerShellDataFile -Path $ModuleEntry.path -ErrorAction SilentlyContinue
            if ($manifestData) {
                if ($manifestData.FunctionsToExport) {
                    $allowedCommands += @($manifestData.FunctionsToExport | Where-Object { $_ -and $_ -ne '*' })
                }
                if ($manifestData.CmdletsToExport) {
                    $allowedCommands += @($manifestData.CmdletsToExport | Where-Object { $_ -and $_ -ne '*' })
                }
            }
        } catch {
            # Fallback: use Test-ModuleManifest for dynamic manifests
            try {
                $manifest = Test-ModuleManifest -Path $ModuleEntry.path -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                if ($manifest) {
                    $allowedCommands += @($manifest.ExportedFunctions.Keys)
                    $allowedCommands += @($manifest.ExportedCmdlets.Keys)
                }
            } catch {
                Write-HubLog -Level Debug -Message "Manifest fallback inspection failed for $($ModuleEntry.name): $($_.Exception.Message)" -Source 'Security'
            }
        }
    }

    # If we couldn't read the manifest, fall back to Get-Command scoped to the module
    if ($allowedCommands.Count -eq 0) {
        $allowedCommands = @(Get-Command -Module $ModuleEntry.name -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }

    if ($CommandName -notin $allowedCommands) {
        Write-HubLog -Level Error -Message "BLOCKED: '$CommandName' is not an exported command of module '$($ModuleEntry.name)'" -Source 'Security'
        return [PSCustomObject]@{
            success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
            output = @([PSCustomObject]@{ stream = 'Error'; message = "Command '$CommandName' is not exported by module '$($ModuleEntry.name)'. Execution denied." })
        }
    }

    # ── 3. Resolve command via module-qualified lookup ──
    # This ensures we get the command FROM this specific module, not a global one with the same name
    $cmd = Get-Command -Name $CommandName -Module $ModuleEntry.name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        # Fallback: try resolving without module scope (some modules register commands differently)
        $cmd = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
        if (-not $cmd -or ($cmd.Module -and $cmd.Module.Name -ne $ModuleEntry.name)) {
            return [PSCustomObject]@{
                success = $false; module = $ModuleEntry.name; command = $CommandName; durationMs = 0
                output = @([PSCustomObject]@{ stream = 'Error'; message = "Command not found in module: $CommandName" })
            }
        }
    }

    # ── 4. Bind parameters (type coercion) ──
    $boundParams = @{}
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        $paramInfo = $cmd.Parameters[$key]
        if ($paramInfo -and ($paramInfo.ParameterType -eq [switch] -or $paramInfo.ParameterType -eq [bool])) {
            # [bool]'false' is $true, so match the text explicitly.
            $boundParams[$key] = ($value -is [bool] -and $value) -or ("$value".Trim().ToLower() -in @('true', '1', 'yes', 'on'))
        } elseif ($paramInfo -and $paramInfo.ParameterType -eq [int]) {
            $boundParams[$key] = [int]$value
        } elseif ($paramInfo -and $paramInfo.ParameterType -eq [string[]]) {
            if ($value -is [string]) { $boundParams[$key] = @($value -split ',\s*') } else { $boundParams[$key] = @($value) }
        } else {
            $boundParams[$key] = $value
        }
    }

    # ── 5. Execute using the resolved CommandInfo object (not a string name) ──
    $output = @()
    try {
        Write-HubLog -Level Info -Message "Executing: $CommandName (module-scoped)" -Source $ModuleEntry.name
        $result = & $cmd @boundParams *>&1
        # Errors arrive on the success stream because of *>&1 — classify by record type,
        # otherwise a command that writes an error record is reported as succeeded.
        $output += @(ConvertTo-HubOutput -Records $result)
        $success = -not ($output | Where-Object { $_.stream -eq 'Error' })
    } catch {
        $output += [PSCustomObject]@{ stream = 'Error'; message = $_.Exception.Message }
        $success = $false
    }

    $duration = ((Get-Date) - $startTime).TotalMilliseconds
    Write-HubLog -Level Info -Message "Completed: $CommandName (${duration}ms, success=$success)" -Source $ModuleEntry.name

    return [PSCustomObject]@{
        success = $success; module = $ModuleEntry.name; command = $CommandName
        durationMs = [math]::Round($duration, 0); output = $output
    }
}
