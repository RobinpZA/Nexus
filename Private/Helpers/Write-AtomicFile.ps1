function Write-AtomicFile {
    <#
    .SYNOPSIS
        Writes text to a file so readers only ever see the old file or the complete new one.
    .DESCRIPTION
        Writes to a uniquely named temp file in the same folder, then renames it over the
        target. The process channel polls command.json/response.json every 200 ms; with a
        plain Out-File a poll could land mid-write and read a truncated request. The rename
        is retried briefly because Windows refuses it while a reader holds the target open.
        Workers/ProcessWorker.ps1 carries a copy of this logic — it runs outside the module.
    .PARAMETER Path
        The file to write.
    .PARAMETER Value
        The text to write (UTF-8, no BOM).
    .EXAMPLE
        Write-AtomicFile -Path $commandFile -Value ($request | ConvertTo-Json -Compress)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temp, $Value, [System.Text.UTF8Encoding]::new($false))

    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::Move($temp, $Path, $true)
            return
        } catch [System.IO.IOException] {
            if ($attempt -ge 10) {
                Remove-Item -Path $temp -Force -ErrorAction SilentlyContinue
                throw
            }
            Start-Sleep -Milliseconds 20
        }
    }
}
