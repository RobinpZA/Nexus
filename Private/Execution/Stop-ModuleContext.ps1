function Stop-ModuleContext {
    <#
    .SYNOPSIS
        Tears down every module runspace and child process Nexus created.
    .DESCRIPTION
        Without this, each session leaves one pwsh process per process-isolated module
        polling its command channel forever, plus its comms folder under Logs/.
        Child processes are asked to exit first and only killed if they do not.
    .PARAMETER TimeoutSeconds
        How long to wait for a child process to exit on its own.
    .EXAMPLE
        Stop-ModuleContext
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$TimeoutSeconds = 5)

    if ($script:BackgroundJobs) {
        foreach ($job in @($script:BackgroundJobs.Values)) {
            if ($job.Mode -eq 'runspace' -and $job.PowerShell) {
                try { $job.PowerShell.Dispose() } catch { Write-HubLog -Level Debug -Message "Failed to dispose job $($job.Id): $($_.Exception.Message)" }
            }
        }
        $script:BackgroundJobs = @{}
    }

    if (-not $script:ModuleRunspaces -or $script:ModuleRunspaces.Count -eq 0) { return }

    foreach ($name in @($script:ModuleRunspaces.Keys)) {
        $entry = $script:ModuleRunspaces[$name]
        if (-not $PSCmdlet.ShouldProcess($name, 'Stop module context')) { continue }

        try {
            if ($entry.Mode -eq 'process' -and $entry.Process) {
                if (-not $entry.Process.HasExited) {
                    # The worker loop watches for this file and exits cleanly.
                    if ($entry.ExitFile) { 'exit' | Out-File $entry.ExitFile -Encoding utf8 -Force }
                    $null = $entry.Process.WaitForExit($TimeoutSeconds * 1000)
                    if (-not $entry.Process.HasExited) {
                        Write-HubLog -Level Warning -Message "Process for $name did not exit — terminating (PID $($entry.Process.Id))"
                        $entry.Process.Kill()
                    }
                }
                if ($entry.CommsDir -and (Test-Path $entry.CommsDir)) {
                    Remove-Item $entry.CommsDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } elseif ($entry.Runspace) {
                $entry.Runspace.Dispose()
            }
            Write-HubLog -Level Debug -Message "Context closed: $name"
        } catch {
            Write-HubLog -Level Warning -Message "Failed to close context for $name : $($_.Exception.Message)"
        }
    }

    $script:ModuleRunspaces = @{}
}
