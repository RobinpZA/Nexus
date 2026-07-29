function Remove-OldLog {
    <#
    .SYNOPSIS
        Deletes daily log files older than the configured retention period.
    .DESCRIPTION
        settings.json has always carried logRetentionDays; nothing acted on it, so logs
        accumulated for the life of the install.
    .PARAMETER RetentionDays
        Age in days beyond which a log file is deleted. 0 disables pruning.
    .EXAMPLE
        Remove-OldLog -RetentionDays 30
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$RetentionDays = 30)

    if ($RetentionDays -le 0) { return }
    if (-not (Test-Path $script:LogDir)) { return }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $stale = @(Get-ChildItem -Path $script:LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff })

    if ($stale.Count -eq 0) { return }

    foreach ($file in $stale) {
        if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove old log')) {
            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    Write-HubLog -Level Info -Message "Removed $($stale.Count) log file(s) older than $RetentionDays day(s)"
}
