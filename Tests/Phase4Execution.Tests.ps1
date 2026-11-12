BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Nexus.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestRegistry.ps1')
    $script:Module = Get-Module Nexus
    $script:FixturePsd1 = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'FixtureModule' 'FixtureModule.psd1')).Path

    # Registry and settings point at a temp folder holding only fixtures; a second entry
    # runs the same fixture in a child process.
    $script:TestRegistry = Enter-TestRegistry -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
    $registry = Get-Content $script:TestRegistry.RegistryPath -Raw | ConvertFrom-Json
    $registry.modules[0] | Add-Member -NotePropertyName isolation -NotePropertyValue 'runspace'
    $process = $registry.modules[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $process.name = 'ProcFixture'
    $process.isolation = 'process'
    $registry.modules = @($registry.modules) + $process
    $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $script:TestRegistry.RegistryPath -Encoding utf8

    $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) "NexusP4_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $script:Temp 'Logs') -Force | Out-Null

    $script:Original = & $script:Module {
        @{ LogDir = $script:LogDir; LogLevel = $script:LogLevel; Token = $script:SessionToken; Stop = $script:StopListener }
    }
    $script:Token = 'phase4-token'
    & $script:Module {
        param($logDir, $token)
        $script:LogDir = $logDir
        $script:SessionToken = $token
        $script:StopListener = $false
        $script:BackgroundJobs = @{}
        $script:SynopsisCache = @{}
    } (Join-Path $script:Temp 'Logs') $script:Token

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
    $script:Send = {
        param([string]$Method = 'GET', [string]$Path, $Body = $null, [switch]$NoToken, [string]$Origin = $script:Base)
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), "$script:Base$Path")
        if (-not $NoToken) { $null = $req.Headers.TryAddWithoutValidation('X-Nexus-Token', $script:Token) }
        if ($Origin) { $null = $req.Headers.TryAddWithoutValidation('Origin', $Origin) }
        if ($null -ne $Body) {
            $req.Content = [System.Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 10 -Compress), [System.Text.Encoding]::UTF8, 'application/json')
        }
        $task = $script:Client.SendAsync($req)
        $ctx = $script:Listener.GetContextAsync().GetAwaiter().GetResult()
        & $script:Module { param($c) Invoke-RequestRouter -Context $c } $ctx
        $resp = $task.GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        [PSCustomObject]@{ Status = [int]$resp.StatusCode; Text = $text; Json = if ($text) { try { $text | ConvertFrom-Json } catch { $null } } else { $null } }
    }

    # Starts a command through the API and returns the job id.
    $script:Start = {
        param([string]$Module = 'FixtureModule', [string]$Command, [hashtable]$Params = @{})
        $r = & $script:Send -Method POST -Path '/api/execute' -Body @{ module = $Module; command = $Command; parameters = $Params }
        $r.Status | Should -Be 200
        $r.Json.mode | Should -Be 'async'
        $r.Json.jobId
    }

    # Polls a job until it leaves 'running'.
    $script:Wait = {
        param([string]$JobId, [int]$TimeoutSeconds = 40)
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            $r = & $script:Send -Path "/api/jobs/$JobId"
            if ($r.Json.status -ne 'running') { return $r }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        return $r
    }

    # Waits until a runspace job has produced at least one record, so a cancel has something to keep.
    $script:WaitForOutput = {
        param([string]$JobId)
        $deadline = (Get-Date).AddSeconds(15)
        do {
            $count = & $script:Module { param($id) $script:BackgroundJobs[$id].Output.Count } $JobId
            if ($count -gt 0) { return }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
    }

    $script:SetMaxRows = {
        param([int]$Rows)
        $s = Get-Content $script:TestRegistry.SettingsPath -Raw | ConvertFrom-Json
        $s | Add-Member -NotePropertyName maxOutputRows -NotePropertyValue $Rows -Force
        $s | ConvertTo-Json -Depth 10 | Set-Content -Path $script:TestRegistry.SettingsPath -Encoding utf8
    }
    $script:Entry = [PSCustomObject]@{ name = 'FixtureModule'; enabled = $true; isolation = 'runspace'; path = $script:FixturePsd1 }
}

AfterAll {
    & $script:Module { Stop-ModuleContext; $script:ModuleRunspaces = @{}; $script:BackgroundJobs = @{}; $script:SynopsisCache = @{} }
    $script:Client.Dispose()
    $script:Listener.Close()
    & $script:Module {
        param($o)
        $script:LogDir = $o.LogDir; $script:LogLevel = $o.LogLevel
        $script:SessionToken = $o.Token; $script:StopListener = $o.Stop
    } $script:Original
    Exit-TestRegistry -Context $script:TestRegistry
    Remove-Item -Path $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Phase 4: DELETE /api/jobs/{id}' {

    AfterEach {
        & $script:Module { Stop-ModuleContext; $script:ModuleRunspaces = @{}; $script:BackgroundJobs = @{} }
    }

    It 'Cancels a running runspace job, keeps its output, frees the context and lets the next command run' {
        $jobId = & $script:Start -Command 'Wait-FixtureSlow' -Params @{ Seconds = 60 }
        & $script:WaitForOutput $jobId

        $del = & $script:Send -Method DELETE -Path "/api/jobs/$jobId"
        $del.Status | Should -Be 200
        $del.Json.success | Should -BeTrue
        $del.Json.status | Should -Be 'cancelled'

        $get = & $script:Send -Path "/api/jobs/$jobId"
        $get.Json.status | Should -Be 'cancelled'
        @($get.Json.output | Where-Object { $_.message -eq 'working' }).Count | Should -Be 1
        $get.Json.truncated | Should -BeFalse
        $get.Json.totalCount | Should -Be 1

        # The stopped pipeline is reaped by the next sync (every request runs one).
        $deadline = (Get-Date).AddSeconds(10)
        do {
            $reaped = & $script:Module { param($id) Sync-BackgroundJob; $script:BackgroundJobs[$id].StopReaped } $jobId
            if (-not $reaped) { Start-Sleep -Milliseconds 100 }
        } while (-not $reaped -and (Get-Date) -lt $deadline)
        $reaped | Should -BeTrue
        (& $script:Module { $script:ModuleRunspaces['FixtureModule'].ActiveAsyncJobId }) | Should -BeNullOrEmpty

        $next = & $script:Wait (& $script:Start -Command 'Get-FixtureValue' -Params @{ Text = 'hi' })
        $next.Json.status | Should -Be 'completed'
        $next.Json.output[0].message | Should -Be 'hi/one'
    }

    It 'Discards the runspace of a pipeline that ignores the stop request after five seconds' {
        $jobId = & $script:Start -Command 'Wait-FixtureBlocking' -Params @{ Seconds = 7 }
        & $script:WaitForOutput $jobId
        (& $script:Send -Method DELETE -Path "/api/jobs/$jobId").Json.status | Should -Be 'cancelled'

        $state = & $script:Module {
            param($id)
            Sync-BackgroundJob
            $before = $script:ModuleRunspaces.ContainsKey('FixtureModule')
            $script:BackgroundJobs[$id].StopRequestedAt = (Get-Date).AddSeconds(-6)
            Sync-BackgroundJob
            [PSCustomObject]@{ Before = $before; After = $script:ModuleRunspaces.ContainsKey('FixtureModule'); Reaped = $script:BackgroundJobs[$id].StopReaped }
        } $jobId
        $state.Before | Should -BeTrue
        $state.After | Should -BeFalse
        $state.Reaped | Should -BeTrue

        # A fresh context is built for the next command.
        $next = & $script:Wait (& $script:Start -Command 'Get-FixtureValue' -Params @{ Text = 'again' })
        $next.Json.status | Should -Be 'completed'
    }

    It 'Cancels a running process job by killing the worker; the next command starts a new one' {
        $jobId = & $script:Start -Module 'ProcFixture' -Command 'Wait-FixtureSlow' -Params @{ Seconds = 60 }
        $workerPid = & $script:Module { $script:ModuleRunspaces['ProcFixture'].Process.Id }

        $del = & $script:Send -Method DELETE -Path "/api/jobs/$jobId"
        $del.Status | Should -Be 200
        $del.Json.status | Should -Be 'cancelled'

        (& $script:Send -Path "/api/jobs/$jobId").Json.status | Should -Be 'cancelled'
        (& $script:Module { $script:ModuleRunspaces.ContainsKey('ProcFixture') }) | Should -BeFalse
        Get-Process -Id $workerPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty

        $next = & $script:Wait (& $script:Start -Module 'ProcFixture' -Command 'Get-FixtureValue' -Params @{ Text = 'proc' })
        $next.Json.status | Should -Be 'completed'
        $next.Json.output[0].message | Should -Be 'proc/one'
        (& $script:Module { $script:ModuleRunspaces['ProcFixture'].Process.Id }) | Should -Not -Be $workerPid
    }

    It 'Returns 404 for an unknown job id' {
        $r = & $script:Send -Method DELETE -Path '/api/jobs/ffffffffffff'
        $r.Status | Should -Be 404
        $r.Json.error | Should -BeTrue
    }

    It 'Returns 409 for a job that has already finished' {
        $jobId = & $script:Start -Command 'Get-FixtureZero'
        (& $script:Wait $jobId).Json.status | Should -Be 'completed'
        $r = & $script:Send -Method DELETE -Path "/api/jobs/$jobId"
        $r.Status | Should -Be 409
        $r.Json.error | Should -BeTrue
        (& $script:Send -Path "/api/jobs/$jobId").Json.status | Should -Be 'completed'
    }

    It 'Returns 401 without the session token' {
        (& $script:Send -Method DELETE -Path '/api/jobs/ffffffffffff' -NoToken).Status | Should -Be 401
    }

    It 'Returns 403 from another origin' {
        (& $script:Send -Method DELETE -Path '/api/jobs/ffffffffffff' -Origin 'http://evil.test').Status | Should -Be 403
    }
}

Describe 'Phase 4: output before a terminating error' {

    AfterAll {
        & $script:Module { Stop-ModuleContext; $script:ModuleRunspaces = @{}; $script:BackgroundJobs = @{} }
    }

    It 'Keeps the records in a synchronous runspace result' {
        $result = & $script:Module { param($e) Invoke-InRunspace -ModuleEntry $e -CommandName 'Get-FixtureThenThrow' } $script:Entry
        $result.success | Should -BeFalse
        @($result.output | Where-Object stream -eq 'Success').message | Should -Be @('one', 'two', 'three')
        @($result.output | Where-Object stream -eq 'Error').message | Should -Be @('fixture boom')
    }

    It 'Keeps the records in an async runspace job' {
        $r = & $script:Wait (& $script:Start -Command 'Get-FixtureThenThrow')
        $r.Json.status | Should -Be 'failed'
        $r.Json.success | Should -BeFalse
        @($r.Json.output | Where-Object stream -eq 'Success').message | Should -Be @('one', 'two', 'three')
        @($r.Json.output | Where-Object stream -eq 'Error').message | Should -Be @('fixture boom')
    }

    It 'Keeps the records in a process job' {
        $r = & $script:Wait (& $script:Start -Module 'ProcFixture' -Command 'Get-FixtureThenThrow')
        $r.Json.status | Should -Be 'failed'
        @($r.Json.output | Where-Object stream -eq 'Success').message | Should -Be @('one', 'two', 'three')
        @($r.Json.output | Where-Object stream -eq 'Error').message | Should -Be @('fixture boom')
    }

    It 'Keeps the records on the CLI path (Invoke-RegisteredCommand)' {
        $result = & $script:Module {
            param($e)
            if (-not $script:ImportedModules) { $script:ImportedModules = @{} }
            $mod = [PSCustomObject]@{ name = 'CliFixture'; path = $e.path }
            try { Invoke-RegisteredCommand -ModuleEntry $mod -CommandName 'Get-FixtureThenThrow' }
            finally { $script:ImportedModules.Remove('CliFixture'); Remove-Module FixtureModule -ErrorAction SilentlyContinue }
        } $script:Entry
        $result.success | Should -BeFalse
        @($result.output | Where-Object stream -eq 'Success').message | Should -Be @('one', 'two', 'three')
        @($result.output | Where-Object stream -eq 'Error').message | Should -Be @('fixture boom')
    }
}

Describe 'Phase 4: maxOutputRows' {

    AfterAll {
        & $script:SetMaxRows 1000
        & $script:Module { Stop-ModuleContext; $script:ModuleRunspaces = @{}; $script:BackgroundJobs = @{} }
    }

    It 'Defaults to 1000 when the setting is absent' {
        & $script:Module { Get-MaxOutputRow } | Should -Be 1000
        (& $script:Module { Read-HubSettings }).maxOutputRows | Should -Be 1000
    }

    It 'Is validated by the settings endpoint (1-100000)' {
        (& $script:Send -Method POST -Path '/api/settings' -Body @{ maxOutputRows = 0 }).Status | Should -Be 400
        (& $script:Send -Method POST -Path '/api/settings' -Body @{ maxOutputRows = 100001 }).Status | Should -Be 400
        (& $script:Send -Method POST -Path '/api/settings' -Body @{ maxOutputRows = 7 }).Status | Should -Be 200
        & $script:Module { Get-MaxOutputRow } | Should -Be 7
    }

    It 'Caps an async runspace job and reports truncated and totalCount' {
        & $script:SetMaxRows 3
        $r = & $script:Wait (& $script:Start -Command 'Get-FixtureRows' -Params @{ Count = 10 })
        $r.Json.status | Should -Be 'completed'
        @($r.Json.output).Count | Should -Be 3
        $r.Json.output[0].data.Index | Should -Be 1
        $r.Json.truncated | Should -BeTrue
        $r.Json.totalCount | Should -Be 10
    }

    It 'Does not mark output within the cap as truncated' {
        & $script:SetMaxRows 3
        $r = & $script:Wait (& $script:Start -Command 'Get-FixtureRows' -Params @{ Count = 3 })
        @($r.Json.output).Count | Should -Be 3
        $r.Json.truncated | Should -BeFalse
        $r.Json.totalCount | Should -Be 3
    }

    It 'Caps a synchronous runspace result' {
        & $script:SetMaxRows 3
        $result = & $script:Module { param($e) Invoke-InRunspace -ModuleEntry $e -CommandName 'Get-FixtureRows' -Parameters @{ Count = 10 } } $script:Entry
        @($result.output).Count | Should -Be 3
        $result.truncated | Should -BeTrue
        $result.totalCount | Should -Be 10
    }

    It 'Caps a process job' {
        & $script:SetMaxRows 3
        $r = & $script:Wait (& $script:Start -Module 'ProcFixture' -Command 'Get-FixtureRows' -Params @{ Count = 10 })
        @($r.Json.output).Count | Should -Be 3
        $r.Json.truncated | Should -BeTrue
        $r.Json.totalCount | Should -Be 10
    }

    It 'Caps the CLI path' {
        & $script:SetMaxRows 3
        $result = & $script:Module {
            param($e)
            if (-not $script:ImportedModules) { $script:ImportedModules = @{} }
            $mod = [PSCustomObject]@{ name = 'CliFixture'; path = $e.path }
            try { Invoke-RegisteredCommand -ModuleEntry $mod -CommandName 'Get-FixtureRows' -Parameters @{ Count = 10 } }
            finally { $script:ImportedModules.Remove('CliFixture'); Remove-Module FixtureModule -ErrorAction SilentlyContinue }
        } $script:Entry
        @($result.output).Count | Should -Be 3
        $result.truncated | Should -BeTrue
        $result.totalCount | Should -Be 10
    }

    It 'Always keeps error records even when the cap is reached' {
        $out = & $script:Module {
            $summary = @{}
            $records = @('a', 'b', 'c', [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('late'), 'late', 'NotSpecified', $null))
            [PSCustomObject]@{
                Output  = @(ConvertTo-HubOutput -Records $records -MaxRows 2 -Summary $summary)
                Summary = $summary
            }
        }
        @($out.Output).Count | Should -Be 3
        @($out.Output | Where-Object stream -eq 'Error').Count | Should -Be 1
        $out.Summary.Truncated | Should -BeTrue
        $out.Summary.Total | Should -Be 4
    }
}

Describe 'Phase 4: falsy single outputs' {

    It 'Keeps a lone 0, $false or empty string' {
        foreach ($value in @(0, $false, '')) {
            $out = & $script:Module { param($v) @(ConvertTo-HubOutput -Records $v) } $value
            @($out).Count | Should -Be 1 -Because "'$value' is a real output"
            $out[0].stream | Should -Be 'Success'
        }
        (& $script:Module { @(ConvertTo-HubOutput -Records 0) })[0].message | Should -Be '0'
    }

    It 'Returns nothing for $null and an empty array' {
        @(& $script:Module { ConvertTo-HubOutput -Records $null }).Count | Should -Be 0
        @(& $script:Module { ConvertTo-HubOutput -Records @() }).Count | Should -Be 0
    }

    It 'Keeps a command output of 0 end to end' {
        $r = & $script:Wait (& $script:Start -Command 'Get-FixtureZero')
        $r.Json.status | Should -Be 'completed'
        @($r.Json.output).Count | Should -Be 1
        $r.Json.output[0].message | Should -Be '0'
        $r.Json.totalCount | Should -Be 1
    }
}

Describe 'Phase 4: synopsis cache' {

    BeforeEach {
        $script:CacheDir = Join-Path $script:Temp "cache_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
        Set-Content -Path (Join-Path $script:CacheDir 'CacheMod.psd1') -Value "@{ RootModule = 'CacheMod.psm1' }" -Encoding utf8
        Set-Content -Path (Join-Path $script:CacheDir 'CacheMod.psm1') -Value '# empty' -Encoding utf8
        $script:CacheEntry = [PSCustomObject]@{ name = 'CacheMod'; path = (Join-Path $script:CacheDir 'CacheMod.psd1') }
        & $script:Module { $script:SynopsisCache = @{} }
        Mock Invoke-ContextMetadataRequest -ModuleName Nexus {
            [PSCustomObject]@{ status = 'ok'; message = $null; data = [PSCustomObject]@{ 'Get-A' = 'Synopsis A' } }
        }
    }

    It 'Does not ask the module for synopses a second time while it is unchanged' {
        $first = & $script:Module { param($e) Get-ContextCommandSynopsis -ModuleEntry $e -CommandNames @('Get-A') } $script:CacheEntry
        $second = & $script:Module { param($e) Get-ContextCommandSynopsis -ModuleEntry $e -CommandNames @('Get-A') } $script:CacheEntry
        $first.status | Should -Be 'ok'
        $first.data.'Get-A' | Should -Be 'Synopsis A'
        $second.data.'Get-A' | Should -Be 'Synopsis A'
        Should -Invoke Invoke-ContextMetadataRequest -ModuleName Nexus -Times 1 -Exactly
    }

    It 'Asks again once the module file has changed' {
        $null = & $script:Module { param($e) Get-ContextCommandSynopsis -ModuleEntry $e -CommandNames @('Get-A') } $script:CacheEntry
        (Get-Item (Join-Path $script:CacheDir 'CacheMod.psm1')).LastWriteTimeUtc = (Get-Date).AddMinutes(5).ToUniversalTime()
        $null = & $script:Module { param($e) Get-ContextCommandSynopsis -ModuleEntry $e -CommandNames @('Get-A') } $script:CacheEntry
        Should -Invoke Invoke-ContextMetadataRequest -ModuleName Nexus -Times 2 -Exactly
    }

    It 'Only asks for commands it has not cached' {
        $null = & $script:Module { param($e) Get-ContextCommandSynopsis -ModuleEntry $e -CommandNames @('Get-A') } $script:CacheEntry
        $null = & $script:Module { param($e) Get-ContextCommandSynopsis -ModuleEntry $e -CommandNames @('Get-A', 'Get-B') } $script:CacheEntry
        Should -Invoke Invoke-ContextMetadataRequest -ModuleName Nexus -Times 1 -Exactly -ParameterFilter { @($Argument).Count -eq 1 -and $Argument -contains 'Get-B' }
    }

    It 'Does not cache a failed request' {
        Mock Invoke-ContextMetadataRequest -ModuleName Nexus { [PSCustomObject]@{ status = 'busy'; message = 'busy'; data = $null } }
        $r = & $script:Module { param($e) Get-ContextCommandSynopsis -ModuleEntry $e -CommandNames @('Get-A') } $script:CacheEntry
        $r.status | Should -Be 'busy'
        $null = & $script:Module { param($e) Get-ContextCommandSynopsis -ModuleEntry $e -CommandNames @('Get-A') } $script:CacheEntry
        Should -Invoke Invoke-ContextMetadataRequest -ModuleName Nexus -Times 2 -Exactly
    }
}

Describe 'Phase 4: Health counts' {
    It 'Reports one healthy module out of one as healthy' {
        $data = & (Get-Module Nexus) {
            param($p)
            function Read-ModuleRegistry { [PSCustomObject]@{ modules = @([PSCustomObject]@{ name = 'Only'; path = $p; enabled = $true }) } }
            function Write-JsonResponse { param($Context, $Data) $script:CapturedHealth = $Data }
            try {
                Get-PortalHealth -Context ([System.Runtime.CompilerServices.RuntimeHelpers]::GetUninitializedObject([System.Net.HttpListenerContext]))
                $script:CapturedHealth
            } finally {
                Remove-Item Function:\Read-ModuleRegistry, Function:\Write-JsonResponse -ErrorAction SilentlyContinue
            }
        } $PSCommandPath
        $data.total   | Should -Be 1
        $data.healthy | Should -Be 1
        $data.status  | Should -Be 'healthy'
    }
}

Describe 'Phase 4: Cancel keeps the context busy until the stop is reaped' {

    AfterEach {
        & $script:Module { Stop-ModuleContext; $script:ModuleRunspaces = @{}; $script:BackgroundJobs = @{} }
    }

    It 'Reports busy without blocking while a cancelled command ignores the stop, then recycles and runs the next command' {
        $jobId = & $script:Start -Command 'Wait-FixtureBlocking' -Params @{ Seconds = 8 }
        & $script:WaitForOutput $jobId
        (& $script:Send -Method DELETE -Path "/api/jobs/$jobId").Json.status | Should -Be 'cancelled'

        # (a) Still busy; a params request answers 409 at once instead of invoking on the runspace.
        (& $script:Module { param($id) Get-ActiveContextJob -ContextEntry $script:ModuleRunspaces['FixtureModule'] } $jobId) | Should -Be $jobId
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $params = & $script:Send -Path '/api/commands/FixtureModule/Get-FixtureValue/params'
        $watch.Stop()
        $params.Status | Should -Be 409
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 1

        $watch.Restart()
        $meta = & $script:Module {
            param($e)
            Invoke-ContextMetadataRequest -ModuleEntry $e -Mode 'params' -Script '1' -Argument 'Get-FixtureValue'
        } $script:Entry
        $watch.Stop()
        $meta.status | Should -Be 'busy'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 1

        # A new command is refused too.
        $start = & $script:Send -Method POST -Path '/api/execute' -Body @{ module = 'FixtureModule'; command = 'Get-FixtureValue'; parameters = @{ Text = 'x' } }
        $start.Json.mode | Should -Not -Be 'async'

        # (b) After the grace period the context is recycled, the busy flag is gone and a new command runs.
        $state = & $script:Module {
            param($id)
            $ctx = $script:ModuleRunspaces['FixtureModule']
            $script:BackgroundJobs[$id].StopRequestedAt = (Get-Date).AddSeconds(-6)
            Sync-BackgroundJob
            [PSCustomObject]@{
                Reaped = $script:BackgroundJobs[$id].StopReaped
                Pointer = $ctx.ActiveAsyncJobId
                Present = $script:ModuleRunspaces.ContainsKey('FixtureModule')
            }
        } $jobId
        $state.Reaped | Should -BeTrue
        $state.Pointer | Should -BeNullOrEmpty
        $state.Present | Should -BeFalse

        $next = & $script:Wait (& $script:Start -Command 'Get-FixtureValue' -Params @{ Text = 'after' })
        $next.Json.status | Should -Be 'completed'
        $next.Json.output[0].message | Should -Be 'after/one'
    }

    It 'Clears the busy flag once a cancelled command that obeys the stop has stopped' {
        $jobId = & $script:Start -Command 'Wait-FixtureSlow' -Params @{ Seconds = 60 }
        & $script:WaitForOutput $jobId
        (& $script:Send -Method DELETE -Path "/api/jobs/$jobId").Json.status | Should -Be 'cancelled'

        $deadline = (Get-Date).AddSeconds(10)
        do {
            $busy = & $script:Module { Sync-BackgroundJob; Get-ActiveContextJob -ContextEntry $script:ModuleRunspaces['FixtureModule'] }
            if ($busy) { Start-Sleep -Milliseconds 100 }
        } while ($busy -and (Get-Date) -lt $deadline)
        $busy | Should -BeNullOrEmpty

        $next = & $script:Wait (& $script:Start -Command 'Get-FixtureValue' -Params @{ Text = 'ok' })
        $next.Json.status | Should -Be 'completed'
    }

    It 'Leaves ActiveAsyncJobId alone when Remove-ModuleContext is given a different job id' {
        $result = & $script:Module {
            $ctx = @{ Name = 'NexusFakeContext'; Mode = 'runspace'; Runspace = $null; Process = $null; CommsDir = $null; ActiveAsyncJobId = 'newjob' }
            Remove-ModuleContext -Context $ctx -JobId 'oldjob'
            $kept = $ctx.ActiveAsyncJobId
            Remove-ModuleContext -Context $ctx -JobId 'newjob'
            $matched = $ctx.ActiveAsyncJobId
            $ctx.ActiveAsyncJobId = 'newjob'
            Remove-ModuleContext -Context $ctx
            [PSCustomObject]@{ Kept = $kept; Matched = $matched; NoId = $ctx.ActiveAsyncJobId }
        }
        $result.Kept | Should -Be 'newjob'
        $result.Matched | Should -BeNullOrEmpty
        $result.NoId | Should -BeNullOrEmpty
    }

    It 'Returns finished from Stop-BackgroundJob when the pipeline has already completed' {
        $jobId = & $script:Start -Command 'Get-FixtureZero'
        $deadline = (Get-Date).AddSeconds(15)
        do {
            $done = & $script:Module { param($id) $script:BackgroundJobs[$id].AsyncResult.IsCompleted } $jobId
            if (-not $done) { Start-Sleep -Milliseconds 50 }
        } while (-not $done -and (Get-Date) -lt $deadline)
        $done | Should -BeTrue

        (& $script:Module { param($id) Stop-BackgroundJob -JobId $id } $jobId) | Should -Be 'finished'
        (& $script:Module { param($id) $script:BackgroundJobs[$id].Status } $jobId) | Should -Be 'completed'
    }
}

Describe 'Phase 4: Error record caps in ConvertTo-HubOutput' {
    It 'Keeps 100 error records, adds one suppression record and counts all 250' {
        $r = & $script:Module {
            $records = foreach ($i in 1..250) {
                [System.Management.Automation.ErrorRecord]::new([System.Exception]::new("error $i"), 'Id', 'NotSpecified', $null)
            }
            $summary = @{}
            $output = @(ConvertTo-HubOutput -Records $records -MaxRows 10 -Summary $summary)
            [PSCustomObject]@{
                Output = $output
                Built = Get-RunspaceCommandOutput -Output $output -Summary $summary
                Summary = $summary
            }
        }
        @($r.Output | Where-Object { $_.stream -eq 'Error' }).Count | Should -Be 100
        $suppressed = @($r.Output | Where-Object { $_.stream -ne 'Error' })
        $suppressed.Count | Should -Be 1
        $suppressed[0].message | Should -Be '150 more errors suppressed'
        $r.Summary['Total'] | Should -Be 250
        $r.Built.totalCount | Should -Be 250
    }

    It 'Truncates a 10000-character message to 4000 characters plus a marker' {
        $out = & $script:Module { @(ConvertTo-HubOutput -Records @(('x' * 10000))) }
        $out.Count | Should -Be 1
        $out[0].message.Length | Should -Be (4000 + '... (truncated)'.Length)
        $out[0].message | Should -BeLike '*... (truncated)'
    }
}
