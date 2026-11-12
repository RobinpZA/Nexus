BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Nexus.psd1') -Force
    $script:Module = Get-Module Nexus
    $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) "NexusP2_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:Temp -Force | Out-Null
    $script:Original = & $script:Module { @{ LogDir = $script:LogDir; PortalRoot = $script:PortalRoot } }
    $logDir = Join-Path $script:Temp 'Logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    & $script:Module { param($d) $script:LogDir = $d } $logDir

    # Portal root with a file, a directory and a bracketed name.
    $script:Portal = Join-Path $script:Temp 'portal'
    New-Item -ItemType Directory -Path (Join-Path $script:Portal 'css') -Force | Out-Null
    Set-Content -Path (Join-Path $script:Portal 'css/app.css') -Value 'body{}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $script:Portal 'css/a[1].css') -Value 'a{}' -Encoding utf8
    & $script:Module { param($d) $script:PortalRoot = $d } $script:Portal

    # Runs a handler against a real loopback HttpListener and returns the client response.
    $script:Invoke = {
        param([scriptblock]$Handler, [hashtable]$Headers = @{})
        $listener = [System.Net.HttpListener]::new()
        $port = & { $p = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $p.Start(); $n = $p.LocalEndpoint.Port; $p.Stop(); $n }
        $listener.Prefixes.Add("http://127.0.0.1:$port/")
        $listener.Start()
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "http://127.0.0.1:$port/x")
            foreach ($k in $Headers.Keys) { $null = $req.Headers.TryAddWithoutValidation($k, $Headers[$k]) }
            $task = $client.SendAsync($req)
            $ctx = $listener.GetContextAsync().GetAwaiter().GetResult()
            & $script:Module $Handler $ctx
            $task.GetAwaiter().GetResult()
        } finally { $client.Dispose(); $listener.Close() }
    }
}

AfterAll {
    & $script:Module { param($o) $script:LogDir = $o.LogDir; $script:PortalRoot = $o.PortalRoot } $script:Original
    Remove-Item -Path $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ScanRootPath' {
    It 'Accepts an existing directory and trims a trailing separator' {
        $r = & $script:Module { param($p) Test-ScanRootPath -Path ($p + '\') } $script:Temp
        $r.Valid | Should -BeTrue
        $r.Path | Should -Be ([System.IO.Path]::GetFullPath($script:Temp))
    }

    It 'Rejects <Name>' -ForEach @(
        @{ Name = 'a relative path'; Path = 'modules\x' }
        @{ Name = 'a drive-relative path'; Path = 'C:foo' }
        @{ Name = 'a missing directory'; Path = 'C:\Nexus_does_not_exist_9f3a' }
        @{ Name = 'a UNC path'; Path = '\\server\share' }
        @{ Name = 'a device path'; Path = '\\?\C:\Windows' }
        @{ Name = 'an empty path'; Path = '' }
    ) {
        $r = & $script:Module { param($p) Test-ScanRootPath -Path $p } $Path
        $r.Valid | Should -BeFalse
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'Rejects a file path' {
        $f = Join-Path $script:Temp 'file.txt'
        Set-Content -Path $f -Value 'x'
        (& $script:Module { param($p) Test-ScanRootPath -Path $p } $f).Valid | Should -BeFalse
    }

    It 'Accepts a UNC path only when allowed' {
        Mock Test-Path { $true } -ModuleName Nexus
        $r = & $script:Module {
            @{ Off = (Test-ScanRootPath -Path '\\server\share\mods\'); On = (Test-ScanRootPath -Path '\\server\share\mods\' -AllowUnc) }
        }
        $r.Off.Valid | Should -BeFalse
        $r.On.Valid | Should -BeTrue
        $r.On.Path | Should -Be '\\server\share\mods'
    }
}

Describe 'Merge-HubSettings path and body validation' {
    BeforeAll {
        $script:Current = [PSCustomObject]@{ scanRoots = @(); publishedModulePaths = @(); allowUncScanRoots = $false }
    }

    It 'Rejects an array body with a fixed message' {
        $msg = & $script:Module { param($c) try { Merge-HubSettings -Current $c -Incoming @(1, 2); '' } catch { $_.Exception.Message } } $script:Current
        $msg | Should -Be 'Settings body must be a JSON object.'
    }

    It 'Rejects a scalar body' {
        $msg = & $script:Module { param($c) try { Merge-HubSettings -Current $c -Incoming 'x'; '' } catch { $_.Exception.Message } } $script:Current
        $msg | Should -Be 'Settings body must be a JSON object.'
    }

    It 'Rejects an invalid scan root' {
        $msg = & $script:Module { param($c) try { Merge-HubSettings -Current $c -Incoming ([PSCustomObject]@{ scanRoots = @('relative') }); '' } catch { $_.Exception.Message } } $script:Current
        $msg | Should -Match "scanRoots"
    }

    It 'Normalises and de-duplicates roots case-insensitively' {
        $upper = $script:Temp.ToUpper()
        $m = & $script:Module { param($c, $a, $b) Merge-HubSettings -Current $c -Incoming ([PSCustomObject]@{ scanRoots = @($a, ($b + '\')) }) } $script:Current $script:Temp $upper
        @($m.scanRoots).Count | Should -Be 1
    }
}

Describe 'Write-StaticFile' {
    It 'Returns 404 for a directory path' {
        $resp = & $script:Invoke { param($c) Write-StaticFile -Context $c -FilePath 'css' }
        [int]$resp.StatusCode | Should -Be 404
    }

    It 'Serves a file whose name contains brackets' {
        $resp = & $script:Invoke { param($c) Write-StaticFile -Context $c -FilePath 'css/a[1].css' }
        [int]$resp.StatusCode | Should -Be 200
    }

    It 'Sends a weak ETag with no-cache, then 304 on a matching If-None-Match' {
        $h = { param($c) Write-StaticFile -Context $c -FilePath 'css/app.css' }
        $first = & $script:Invoke $h
        [int]$first.StatusCode | Should -Be 200
        $etag = $first.Headers.ETag.ToString()
        $etag | Should -Match '^W/"\d+-\d+"$'
        $first.Headers.CacheControl.NoCache | Should -BeTrue

        $second = & $script:Invoke $h @{ 'If-None-Match' = $etag }
        [int]$second.StatusCode | Should -Be 304
        $second.Content.Headers.ContentLength | Should -Be 0
    }

    It 'Returns 200 when If-None-Match does not match' {
        $resp = & $script:Invoke { param($c) Write-StaticFile -Context $c -FilePath 'css/app.css' } @{ 'If-None-Match' = 'W/"1-1"' }
        [int]$resp.StatusCode | Should -Be 200
    }
}

Describe 'Write-JsonResponse' {
    It 'Sends no-store, nosniff, no-referrer and closes the connection' {
        $resp = & $script:Invoke { param($c) Write-JsonResponse -Context $c -Data @{ ok = $true } }
        $resp.Headers.CacheControl.NoStore | Should -BeTrue
        $resp.Headers.GetValues('Referrer-Policy') | Should -Be 'no-referrer'
        $resp.Headers.GetValues('X-Content-Type-Options') | Should -Be 'nosniff'
        $resp.Headers.ConnectionClose | Should -BeTrue
    }
}
