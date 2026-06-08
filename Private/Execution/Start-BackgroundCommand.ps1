function Start-BackgroundCommand {
    <#
    .SYNOPSIS
        Runs a registered command in a background runspace so the HTTP listener stays responsive.
        Returns a job ID immediately. Use Get-BackgroundCommandResult to poll for completion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ModuleEntry,
        [Parameter(Mandatory)][string]$CommandName,
        [hashtable]$Parameters = @{}
    )

    # Initialise job tracker if not present
    if (-not $script:BackgroundJobs) {
        $script:BackgroundJobs = @{}
    }

    $jobId = [guid]::NewGuid().ToString('N').Substring(0, 12)

    # Build the script to run in the background runspace
    $modulePath = $ModuleEntry.path
    $moduleName = $ModuleEntry.name

    $scriptBlock = {
        param($ModulePath, $ModuleName, $CommandName, $Params)

        $output = [System.Collections.Generic.List[PSCustomObject]]::new()
        $startTime = Get-Date

        try {
            # Import the module in this runspace
            Import-Module $ModulePath -Force -DisableNameChecking -ErrorAction Stop

            # Resolve command from the module
            $cmd = Get-Command -Name $CommandName -Module $ModuleName -ErrorAction SilentlyContinue
            if (-not $cmd) {
                $cmd = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
            }

            if (-not $cmd) {
                $output.Add([PSCustomObject]@{ stream = 'Error'; message = "Command not found: $CommandName" })
                return [PSCustomObject]@{ success = $false; output = @($output); durationMs = 0 }
            }

            # Type coercion for parameters
            $boundParams = @{}
            foreach ($key in $Params.Keys) {
                $value = $Params[$key]
                $paramInfo = $cmd.Parameters[$key]
                if ($paramInfo -and $paramInfo.ParameterType -eq [switch]) {
                    $boundParams[$key] = [bool]$value
                } elseif ($paramInfo -and $paramInfo.ParameterType -eq [int]) {
                    $boundParams[$key] = [int]$value
                } else {
                    $boundParams[$key] = $value
                }
            }

            $result = & $cmd @boundParams *>&1

            foreach ($item in $result) {
                $stream = switch ($item.GetType().Name) {
                    'ErrorRecord'       { 'Error' }
                    'WarningRecord'     { 'Warning' }
                    'InformationRecord' { 'Information' }
                    'VerboseRecord'     { 'Verbose' }
                    'DebugRecord'       { 'Debug' }
                    default             { 'Success' }
                }
                $output.Add([PSCustomObject]@{ stream = $stream; message = $item.ToString() })
            }

            $duration = ((Get-Date) - $startTime).TotalMilliseconds
            return [PSCustomObject]@{ success = $true; output = @($output); durationMs = [math]::Round($duration, 0) }
        } catch {
            $output.Add([PSCustomObject]@{ stream = 'Error'; message = $_.Exception.Message })
            $duration = ((Get-Date) - $startTime).TotalMilliseconds
            return [PSCustomObject]@{ success = $false; output = @($output); durationMs = [math]::Round($duration, 0) }
        }
    }

    # Create and start the PowerShell runspace job
    $ps = [PowerShell]::Create()
    $ps.AddScript($scriptBlock).AddArgument($modulePath).AddArgument($moduleName).AddArgument($CommandName).AddArgument($Parameters) | Out-Null

    $asyncResult = $ps.BeginInvoke()

    # Track the job
    $script:BackgroundJobs[$jobId] = @{
        Id          = $jobId
        Module      = $moduleName
        Command     = $CommandName
        PowerShell  = $ps
        AsyncResult = $asyncResult
        StartedAt   = Get-Date
        Status      = 'running'
        Result      = $null
    }

    Write-HubLog -Level Info -Message "Background job started: $jobId ($moduleName/$CommandName)"

    return $jobId
}
