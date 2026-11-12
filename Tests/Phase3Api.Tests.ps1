BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Nexus.psd1') -Force
    $script:Module = Get-Module Nexus

    # Everything the API writes goes to a temp data root.
    $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) "NexusP3Api_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $script:Temp 'Logs') -Force | Out-Null
    $script:SettingsPath = Join-Path $script:Temp 'settings.json'

    $script:Original = & $script:Module {
        @{ Settings = $script:SettingsFile; LogDir = $script:LogDir; LogLevel = $script:LogLevel
           Token = $script:SessionToken; Stop = $script:StopListener; Routes = $script:PortalRoutes }
    }

    $script:Seed = {
        @{
            defaultPort = 8090; portRange = @(8090, 8099); openBrowserOnStart = $false
            logLevel = 'Error'; logRetentionDays = 30; scanOnStartup = $false; scanRoots = @()
            allowUncScanRoots = $false; scanDepth = 2; scanExclude = @('node_modules')
            scanPublishedModules = $false; publishedModulePaths = @(); theme = 'dark'
            favouriteCommands = @()
            recentCommands = @(@{ module = 'M'; command = 'Get-One' }, @{ module = 'M'; command = 'Get-Two' })
            maxRecentCommands = 20
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $script:SettingsPath -Encoding utf8
    }
    & $script:Seed

    $script:Token = 'phase3-api-token'
    & $script:Module {
        param($settings, $logDir, $token)
        $script:SettingsFile = $settings
        $script:LogDir = $logDir
        $script:SessionToken = $token
        $script:StopListener = $false
    } $script:SettingsPath (Join-Path $script:Temp 'Logs') $script:Token

    $script:Listener = [System.Net.HttpListener]::new()
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $script:Port = $probe.LocalEndpoint.Port; $probe.Stop()
    $script:Base = "http://127.0.0.1:$script:Port"
    $script:Listener.Prefixes.Add("$script:Base/")
    $script:Listener.Start()

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseCookies = $false
    $script:Client = [System.Net.Http.HttpClient]::new($handler)

    # Sends one request from the thread pool while this thread serves it through the real router.
    # Defaults to a valid token and same-origin header; pass -NoToken / -Origin to vary them.
    $script:Send = {
        param([string]$Method = 'GET', [string]$Path, $Body = $null, [switch]$NoToken, [string]$Origin = $script:Base)
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), "$script:Base$Path")
        if (-not $NoToken) { $null = $req.Headers.TryAddWithoutValidation('X-Nexus-Token', $script:Token) }
        if ($Origin) { $null = $req.Headers.TryAddWithoutValidation('Origin', $Origin) }
        if ($null -ne $Body) {
            $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
            $req.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
        }
        $task = $script:Client.SendAsync($req)
        $ctx = $script:Listener.GetContextAsync().GetAwaiter().GetResult()
        & $script:Module { param($c) Invoke-RequestRouter -Context $c } $ctx
        $resp = $task.GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        [PSCustomObject]@{
            Status = [int]$resp.StatusCode
            Text   = $text
            Json   = if ($text) { try { $text | ConvertFrom-Json } catch { $null } } else { $null }
        }
    }
    $script:ReadFile = { Get-Content -Path $script:SettingsPath -Raw -Encoding utf8 | ConvertFrom-Json }
}

AfterAll {
    $script:Client.Dispose()
    $script:Listener.Close()
    & $script:Module {
        param($o)
        $script:SettingsFile = $o.Settings; $script:LogDir = $o.LogDir; $script:LogLevel = $o.LogLevel
        $script:SessionToken = $o.Token; $script:StopListener = $o.Stop
    } $script:Original
    Remove-Item -Path $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'API: settings' {
    BeforeEach { & $script:Seed }

    It 'GET /api/settings returns the settings plus the hub version' {
        $r = & $script:Send -Path '/api/settings'
        $r.Status | Should -Be 200
        $r.Json.defaultPort | Should -Be 8090
        $r.Json.theme | Should -Be 'dark'
        $r.Json.hubVersion | Should -Not -BeNullOrEmpty
    }

    It 'POST /api/settings with a valid change persists it to the settings file' {
        $r = & $script:Send -Method POST -Path '/api/settings' -Body @{ theme = 'light'; scanDepth = 4 }
        $r.Status | Should -Be 200
        $r.Json.success | Should -BeTrue

        $onDisk = & $script:ReadFile
        $onDisk.theme | Should -Be 'light'
        $onDisk.scanDepth | Should -Be 4
        $onDisk.defaultPort | Should -Be 8090   # untouched keys survive the merge
    }

    It 'POST /api/settings with an invalid value returns 400 and leaves the file unchanged' {
        $r = & $script:Send -Method POST -Path '/api/settings' -Body @{ defaultPort = 70000 }
        $r.Status | Should -Be 400
        (& $script:ReadFile).defaultPort | Should -Be 8090
    }

    It 'POST /api/settings with a non-object body returns 400' {
        $r = & $script:Send -Method POST -Path '/api/settings' -Body '[1,2]'
        $r.Status | Should -Be 400
    }

    It 'POST /api/settings from another origin is rejected with 403' {
        $r = & $script:Send -Method POST -Path '/api/settings' -Body @{ theme = 'light' } -Origin 'http://evil.test'
        $r.Status | Should -Be 403
        (& $script:ReadFile).theme | Should -Be 'dark'
    }
}

Describe 'API: favourites' {
    BeforeEach { & $script:Seed }

    It 'POST adds a favourite, is idempotent, and DELETE removes it' {
        $add = & $script:Send -Method POST -Path '/api/favourites' -Body @{ module = 'Mod'; command = 'Get-Thing' }
        $add.Status | Should -Be 200
        @($add.Json.favourites).Count | Should -Be 1

        $again = & $script:Send -Method POST -Path '/api/favourites' -Body @{ module = 'Mod'; command = 'Get-Thing' }
        @($again.Json.favourites).Count | Should -Be 1

        $list = & $script:Send -Path '/api/favourites'
        @($list.Json.favourites).Count | Should -Be 1
        $list.Json.favourites[0].module | Should -Be 'Mod'
        @((& $script:ReadFile).favouriteCommands).Count | Should -Be 1

        $del = & $script:Send -Method DELETE -Path '/api/favourites' -Body @{ module = 'Mod'; command = 'Get-Thing' }
        $del.Status | Should -Be 200
        @($del.Json.favourites).Count | Should -Be 0
        @((& $script:ReadFile).favouriteCommands).Count | Should -Be 0
    }

    It 'POST without module and command returns 400' {
        (& $script:Send -Method POST -Path '/api/favourites' -Body @{ module = 'Mod' }).Status | Should -Be 400
    }
}

Describe 'API: recent commands' {
    BeforeEach { & $script:Seed }

    It 'GET lists recent commands and DELETE clears them' {
        $list = & $script:Send -Path '/api/recent'
        $list.Status | Should -Be 200
        @($list.Json.recent).Count | Should -Be 2

        $del = & $script:Send -Method DELETE -Path '/api/recent'
        $del.Status | Should -Be 200
        $del.Json.success | Should -BeTrue

        @((& $script:Send -Path '/api/recent').Json.recent).Count | Should -Be 0
        @((& $script:ReadFile).recentCommands).Count | Should -Be 0
    }
}

Describe 'API: shutdown' {
    BeforeEach { & $script:Module { $script:StopListener = $false } }
    AfterEach { & $script:Module { $script:StopListener = $false } }

    It 'POST /api/shutdown sets the stop flag and answers 200' {
        (& $script:Module { $script:StopListener }) | Should -BeFalse
        $r = & $script:Send -Method POST -Path '/api/shutdown'
        $r.Status | Should -Be 200
        $r.Json.status | Should -Be 'shutting down'
        (& $script:Module { $script:StopListener }) | Should -BeTrue
    }

    It 'POST /api/shutdown without the token is 401 and does not set the flag' {
        $r = & $script:Send -Method POST -Path '/api/shutdown' -NoToken
        $r.Status | Should -Be 401
        (& $script:Module { $script:StopListener }) | Should -BeFalse
    }

    It 'GET /api/shutdown is 405 and does not set the flag' {
        $r = & $script:Send -Method GET -Path '/api/shutdown'
        $r.Status | Should -Be 405
        (& $script:Module { $script:StopListener }) | Should -BeFalse
    }
}

Describe 'API: routing and auth' {
    It 'An unknown /api route returns 404 with the token' {
        $r = & $script:Send -Path '/api/does-not-exist'
        $r.Status | Should -Be 404
        $r.Json.error | Should -BeTrue
    }

    It 'An unknown /api route returns 401 without the token' {
        (& $script:Send -Path '/api/does-not-exist' -NoToken).Status | Should -Be 401
    }

    It 'A known /api route returns 401 without the token' {
        (& $script:Send -Path '/api/settings' -NoToken).Status | Should -Be 401
    }

    It 'A wrong method on a known route returns 405' {
        (& $script:Send -Method DELETE -Path '/api/settings').Status | Should -Be 405
    }
}
