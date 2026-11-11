function Stop-ModuleContext {
    <#
    .SYNOPSIS
        Tears down module runspaces and child processes Nexus created.
    .DESCRIPTION
        Without this, each session leaves one pwsh process per process-isolated module
        polling its command channel forever, plus its comms folder under Logs/.
        Child processes are asked to exit first and only killed (with their process tree)
        if they do not. With -Name only that module's context is stopped; otherwise every
        context and background job is stopped.
    .PARAMETER Name
        Stop only the context of this module. Without it, all contexts are stopped.
    .PARAMETER TimeoutSeconds
        How long to wait for a child process to exit on its own.
    .EXAMPLE
        Stop-ModuleContext
    .EXAMPLE
        Stop-ModuleContext -Name 'MyTool'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 5
    )

    $single = $PSBoundParameters.ContainsKey('Name')

    if (-not $single -and $script:BackgroundJobs -and $PSCmdlet.ShouldProcess('all background jobs', 'Dispose')) {
        foreach ($job in @($script:BackgroundJobs.Values)) {
            if ($job.Mode -eq 'runspace' -and $job.PowerShell) {
                try { $job.PowerShell.Dispose() } catch { Write-HubLog -Level Debug -Message "Failed to dispose job $($job.Id): $($_.Exception.Message)" }
            }
        }
        $script:BackgroundJobs = @{}
    }

    if (-not $script:ModuleRunspaces -or $script:ModuleRunspaces.Count -eq 0) { return }

    $names = if ($single) { @($Name) } else { @($script:ModuleRunspaces.Keys) }
    foreach ($contextName in $names) {
        if (-not $script:ModuleRunspaces.ContainsKey($contextName)) { continue }
        $entry = $script:ModuleRunspaces[$contextName]
        if (-not $PSCmdlet.ShouldProcess($contextName, 'Stop module context')) { continue }

        try {
            if ($entry.Mode -eq 'process' -and $entry.Process) {
                if (-not $entry.Process.HasExited) {
                    # The worker loop watches for this file and exits cleanly.
                    if ($entry.ExitFile) { 'exit' | Out-File $entry.ExitFile -Encoding utf8 -Force }
                    $null = $entry.Process.WaitForExit($TimeoutSeconds * 1000)
                    if (-not $entry.Process.HasExited) {
                        Write-HubLog -Level Warning -Message "Process for $contextName did not exit - terminating (PID $($entry.Process.Id))"
                        $entry.Process.Kill($true)
                    }
                }
                if ($entry.Process -is [System.IDisposable]) { $entry.Process.Dispose() }
                if ($entry.CommsDir -and (Test-Path $entry.CommsDir)) {
                    Remove-Item $entry.CommsDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } elseif ($entry.Runspace) {
                $entry.Runspace.Dispose()
            }
            Write-HubLog -Level Debug -Message "Context closed: $contextName"
        } catch {
            Write-HubLog -Level Warning -Message "Failed to close context for $contextName : $($_.Exception.Message)"
        }
        $script:ModuleRunspaces.Remove($contextName)
    }
}
