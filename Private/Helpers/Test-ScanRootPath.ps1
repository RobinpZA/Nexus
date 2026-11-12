function Test-ScanRootPath {
    <#
    .SYNOPSIS
        Validates and normalises a directory path destined for scanRoots or publishedModulePaths.
    .DESCRIPTION
        SECURITY: Invoke-ModuleScan walks these directories and registers whatever it finds as
        runnable, so a path must be an absolute, existing local folder. Rejected: relative and
        drive-relative paths (C:foo), device paths (\\?\ and \\.\), and UNC paths unless
        -AllowUnc is set (settings key allowUncScanRoots). The returned Path is fully
        qualified with trailing separators trimmed (a drive root such as C:\ is kept).
    .PARAMETER Path
        The candidate path.
    .PARAMETER AllowUnc
        Permit \\server\share paths.
    .EXAMPLE
        $check = Test-ScanRootPath -Path 'C:\Modules\'
        if (-not $check.Valid) { $check.Reason }
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [switch]$AllowUnc
    )

    $fail = { param($reason) [PSCustomObject]@{ Valid = $false; Path = $Path; Reason = $reason } }

    if ([string]::IsNullOrWhiteSpace($Path)) { return & $fail 'Path is empty.' }
    $candidate = $Path.Trim()

    if ($candidate.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) { return & $fail 'Path contains invalid characters.' }
    if ($candidate -match '^[\\/]{2}[?.][\\/]') { return & $fail 'Device paths are not allowed.' }

    $isUnc = $candidate -match '^[\\/]{2}[^\\/]'
    if ($isUnc) {
        if (-not $AllowUnc) { return & $fail 'UNC paths are not allowed (enable allowUncScanRoots to permit them).' }
    } elseif ($candidate -match '^[A-Za-z]:(?![\\/])') {
        return & $fail 'Drive-relative paths are not allowed; use a full path such as C:\Modules.'
    } elseif ($candidate -notmatch '^[A-Za-z]:[\\/]') {
        return & $fail 'Path must be absolute (for example C:\Modules).'
    }

    try { $full = [System.IO.Path]::GetFullPath($candidate) }
    catch { return & $fail 'Path is not valid.' }

    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }

    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        return & $fail 'Directory does not exist.'
    }

    return [PSCustomObject]@{ Valid = $true; Path = $full; Reason = $null }
}
