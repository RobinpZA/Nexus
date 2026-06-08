function Get-BackgroundCommandResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JobId)

    if (-not $script:BackgroundJobs -or -not $script:BackgroundJobs.ContainsKey($JobId)) {
        return [PSCustomObject]@{ id = $JobId; status = 'not_found'; result = $null }
    }

    $job = $script:BackgroundJobs[$JobId]

    if (-not $job.AsyncResult.IsCompleted) {
        $elapsed = ((Get-Date) - $job.StartedAt).TotalSeconds
        return [PSCustomObject]@{
            id = $JobId; status = 'running'; module = $job.Module; command = $job.Command
            elapsed = [math]::Round($elapsed, 1); result = $null
        }
    }

    # Completed — collect results if not already done
    if ($job.Status -eq 'running') {
        try {
            $results = $job.PowerShell.EndInvoke($job.AsyncResult)
            $output = @()

            foreach ($item in $results) {
                $output += [PSCustomObject]@{ stream = 'Success'; message = $item.ToString() }
            }
            foreach ($err in $job.PowerShell.Streams.Error) {
                $output += [PSCustomObject]@{ stream = 'Error'; message = $err.ToString() }
            }
            foreach ($warn in $job.PowerShell.Streams.Warning) {
                $output += [PSCustomObject]@{ stream = 'Warning'; message = $warn.ToString() }
            }
            foreach ($info in $job.PowerShell.Streams.Information) {
                $output += [PSCustomObject]@{ stream = 'Information'; message = $info.ToString() }
            }

            $success = $job.PowerShell.Streams.Error.Count -eq 0
            $duration = ((Get-Date) - $job.StartedAt).TotalMilliseconds

            $job.Result = [PSCustomObject]@{
                success = $success; output = $output; durationMs = [math]::Round($duration, 0)
            }
            $job.Status = if ($success) { 'completed' } else { 'failed' }

        } catch {
            $duration = ((Get-Date) - $job.StartedAt).TotalMilliseconds
            $job.Result = [PSCustomObject]@{
                success = $false
                output = @([PSCustomObject]@{ stream = 'Error'; message = $_.Exception.Message })
                durationMs = [math]::Round($duration, 0)
            }
            $job.Status = 'failed'
        } finally {
            # Dispose the PowerShell instance but KEEP the runspace alive
            # (persistent runspaces maintain auth state between commands)
            $job.PowerShell.Dispose()

            if ($script:ModuleRunspaces -and $job.Module -and $script:ModuleRunspaces.ContainsKey($job.Module)) {
                $rsEntry = $script:ModuleRunspaces[$job.Module]
                if ($rsEntry -and $rsEntry.Mode -eq 'runspace' -and $rsEntry.ActiveAsyncJobId -eq $JobId) {
                    $rsEntry.ActiveAsyncJobId = $null
                    $rsEntry.LastUsed = Get-Date
                }
            }
        }

        Write-HubLog -Level Info -Message "Background job $JobId completed ($($job.Status))"
    }

    return [PSCustomObject]@{
        id = $JobId; status = $job.Status; module = $job.Module; command = $job.Command
        result = $job.Result
    }
}
