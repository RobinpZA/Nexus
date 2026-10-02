BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Nexus.psd1'
    Import-Module $modulePath -Force
}

Describe 'Execution: Output Classification' {

    It 'Labels records by type, not by stream of origin' {
        # Commands run with *>&1, so every record arrives on the success stream.
        $output = & (Get-Module Nexus) {
            $records = @(
                'plain text'
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new('boom'), 'id', 'NotSpecified', $null)
                [System.Management.Automation.WarningRecord]::new('careful')
            )
            @(ConvertTo-HubOutput -Records $records)
        }

        $output.Count | Should -Be 3
        $output[0].stream | Should -Be 'Success'
        $output[1].stream | Should -Be 'Error'
        $output[2].stream | Should -Be 'Warning'
    }

    It 'Returns an empty collection for no records' {
        $output = & (Get-Module Nexus) { @(ConvertTo-HubOutput -Records $null) }
        $output.Count | Should -Be 0
    }
}

Describe 'Execution: Context Gating' {

    AfterEach {
        & (Get-Module Nexus) { $script:BackgroundJobs = @{} }
    }

    It 'Reports the running job holding a context' {
        $active = & (Get-Module Nexus) {
            $script:BackgroundJobs = @{ 'job1' = @{ Id = 'job1'; Status = 'running'; StartedAt = (Get-Date) } }
            $context = @{ ActiveAsyncJobId = 'job1' }
            Get-ActiveContextJob -ContextEntry $context
        }
        $active | Should -Be 'job1'
    }

    It 'Clears a stale pointer left by a finished job' {
        $result = & (Get-Module Nexus) {
            $script:BackgroundJobs = @{ 'job1' = @{ Id = 'job1'; Status = 'completed'; StartedAt = (Get-Date) } }
            $context = @{ ActiveAsyncJobId = 'job1' }
            [PSCustomObject]@{ Active = (Get-ActiveContextJob -ContextEntry $context); Pointer = $context.ActiveAsyncJobId }
        }
        $result.Active | Should -BeNullOrEmpty
        $result.Pointer | Should -BeNullOrEmpty
    }
}

Describe 'Execution: Job Pruning' {

    AfterEach {
        & (Get-Module Nexus) { $script:BackgroundJobs = @{} }
    }

    It 'Keeps running jobs and trims the oldest finished ones' {
        $state = & (Get-Module Nexus) {
            $script:BackgroundJobs = @{}
            foreach ($i in 1..10) {
                $script:BackgroundJobs["done$i"] = @{ Id = "done$i"; Status = 'completed'; StartedAt = (Get-Date).AddMinutes(-$i) }
            }
            $script:BackgroundJobs['live'] = @{ Id = 'live'; Status = 'running'; StartedAt = (Get-Date).AddHours(-5) }

            Remove-CompletedJob -Keep 3
            [PSCustomObject]@{
                Count    = $script:BackgroundJobs.Count
                HasLive  = $script:BackgroundJobs.ContainsKey('live')
                HasNewest = $script:BackgroundJobs.ContainsKey('done1')
                HasOldest = $script:BackgroundJobs.ContainsKey('done10')
            }
        }

        $state.Count | Should -Be 4          # 3 finished + the running one
        $state.HasLive | Should -BeTrue      # never pruned, however old
        $state.HasNewest | Should -BeTrue
        $state.HasOldest | Should -BeFalse
    }
}

Describe 'Execution: Connection State' {

    It 'Reports no session for a module with no live context' {
        $state = & (Get-Module Nexus) {
            $script:ModuleRunspaces = @{}
            Get-ContextConnectionState -ModuleEntry ([PSCustomObject]@{ name = 'NotRunning'; path = 'C:\none.psd1' })
        }

        $state.status | Should -Be 'ok'
        $state.data.active | Should -BeFalse
        @($state.data.providers).Count | Should -Be 0
    }

    It 'Does not create a context just to answer' {
        $contextCount = & (Get-Module Nexus) {
            $script:ModuleRunspaces = @{}
            $null = Get-ContextConnectionState -ModuleEntry ([PSCustomObject]@{ name = 'NotRunning'; path = 'C:\none.psd1' })
            $script:ModuleRunspaces.Count
        }
        $contextCount | Should -Be 0
    }

    It 'Reports nothing for a context with no Graph or Exchange loaded' {
        $result = & (Get-Module Nexus) {
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.Open()
            $ps = [PowerShell]::Create()
            $ps.Runspace = $runspace
            try {
                $null = $ps.AddScript((Get-ConnectionStateScript)).AddArgument('status')
                @($ps.Invoke())[0]
            } finally { $ps.Dispose(); $runspace.Dispose() }
        }

        @($result.providers).Count | Should -Be 0
    }

    It 'Reports a signed-in provider and flags a user-wide cached sign-in' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\FakeGraphModule\FakeGraphModule.psd1'
        $result = & (Get-Module Nexus) {
            param($manifest)
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.Open()
            $ps = [PowerShell]::Create()
            $ps.Runspace = $runspace
            try {
                $null = $ps.AddScript("Import-Module '$manifest' -Force; Connect-FakeGraph | Out-Null")
                $null = $ps.Invoke()
                $ps.Commands.Clear()
                $null = $ps.AddScript((Get-ConnectionStateScript)).AddArgument('status')
                @($ps.Invoke())[0]
            } finally { $ps.Dispose(); $runspace.Dispose() }
        } $fixture

        $graph = @($result.providers) | Where-Object name -eq 'Microsoft Graph'
        $graph.connected | Should -BeTrue
        $graph.account | Should -Be 'tester@contoso.onmicrosoft.com'
        $graph.shared | Should -BeTrue   # ContextScope CurrentUser = cached for the user
    }

    It 'Signs the context out on disconnect' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\FakeGraphModule\FakeGraphModule.psd1'
        $result = & (Get-Module Nexus) {
            param($manifest)
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.Open()
            $ps = [PowerShell]::Create()
            $ps.Runspace = $runspace
            try {
                $null = $ps.AddScript("Import-Module '$manifest' -Force; Connect-FakeGraph | Out-Null")
                $null = $ps.Invoke()
                $ps.Commands.Clear()
                $null = $ps.AddScript((Get-ConnectionStateScript)).AddArgument('disconnect')
                @($ps.Invoke())[0]
            } finally { $ps.Dispose(); $runspace.Dispose() }
        } $fixture

        (@($result.providers) | Where-Object name -eq 'Microsoft Graph').connected | Should -BeFalse
    }
}

Describe 'Execution: Command Metadata Script' {

    It 'Describes a command without importing it into the Nexus session' {
        $meta = & (Get-Module Nexus) {
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.Open()
            $ps = [PowerShell]::Create()
            $ps.Runspace = $runspace
            try {
                $null = $ps.AddScript((Get-CommandMetadataScript)).AddArgument('Get-Date')
                @($ps.Invoke())[0]
            } finally { $ps.Dispose(); $runspace.Dispose() }
        }

        $meta.command | Should -Be 'Get-Date'
        $meta.parameters.name | Should -Contain 'Format'
        # Common parameters are filtered out of the portal's form
        $meta.parameters.name | Should -Not -Contain 'ErrorAction'
    }
}

Describe 'Execution: Connection Commands Run Async' {
    # Runspace-mode Connect/Disconnect used to run synchronously so a caller could wait
    # on an interactive auth prompt. Testing showed that runspace never has one to wait
    # on (New-RunspaceContext's "Default Host" rejects Read-Host outright), so the
    # carve-out was removed — see Invoke-InRunspace.ps1's description for the full
    # reasoning. These tests pin the resulting behaviour.

    AfterEach {
        & (Get-Module Nexus) {
            $script:BackgroundJobs = @{}
            if ($script:ModuleRunspaces.ContainsKey('FakeGraphModule')) {
                $entry = $script:ModuleRunspaces['FakeGraphModule']
                if ($entry.Runspace) { $entry.Runspace.Dispose() }
                $script:ModuleRunspaces.Remove('FakeGraphModule')
            }
        }
    }

    It 'Returns a job id for a runspace-mode Connect command instead of blocking' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\FakeGraphModule\FakeGraphModule.psd1'
        $outcome = & (Get-Module Nexus) {
            param($path)
            # Force runspace mode: the fixture's own Disconnect-MgGraph shadow function
            # substring-matches the (case-insensitive) 'Connect-MgGraph' isolation
            # heuristic, which would otherwise route this into process isolation instead
            # — already async before this fix, so it wouldn't exercise the new behaviour.
            $mod = [PSCustomObject]@{ name = 'FakeGraphModule'; path = $path; isolation = 'runspace' }
            Invoke-InRunspace -ModuleEntry $mod -CommandName 'Connect-FakeGraph' -Parameters @{} -Async
        } $fixture

        $outcome | Should -BeOfType [string]
        $outcome.Length | Should -Be 12   # jobId format: guid, no dashes, first 12 chars
    }

    It 'Marks the runspace context Connected once that job completes' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\FakeGraphModule\FakeGraphModule.psd1'
        $result = & (Get-Module Nexus) {
            param($path)
            # Force runspace mode: the fixture's own Disconnect-MgGraph shadow function
            # substring-matches the (case-insensitive) 'Connect-MgGraph' isolation
            # heuristic, which would otherwise route this into process isolation instead
            # — already async before this fix, so it wouldn't exercise the new behaviour.
            $mod = [PSCustomObject]@{ name = 'FakeGraphModule'; path = $path; isolation = 'runspace' }
            $jobId = Invoke-InRunspace -ModuleEntry $mod -CommandName 'Connect-FakeGraph' -Parameters @{} -Async

            $deadline = (Get-Date).AddSeconds(5)
            $status = $null
            while ((Get-Date) -lt $deadline) {
                $status = Get-BackgroundCommandResult -JobId $jobId
                if ($status.status -ne 'running') { break }
                Start-Sleep -Milliseconds 50
            }

            [PSCustomObject]@{
                Status    = $status.status
                Success   = $status.result.success
                Connected = $script:ModuleRunspaces['FakeGraphModule'].Connected
            }
        } $fixture

        $result.Status | Should -Be 'completed'
        $result.Success | Should -BeTrue
        $result.Connected | Should -BeTrue
    }
}

Describe 'Execution: Runspace Job Timeout' {
    # Process-mode jobs already timed out (TimeoutAt in Start-ProcessAsync); runspace
    # jobs previously had no equivalent, so a hung command held its context's
    # ActiveAsyncJobId forever.

    It 'Fails a hung job once it passes its TimeoutAt, freeing the context' {
        $result = & (Get-Module Nexus) {
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.Open()
            $ps = [PowerShell]::Create()
            $ps.Runspace = $runspace
            $null = $ps.AddScript('Start-Sleep -Seconds 30')
            $async = $ps.BeginInvoke()

            $context = @{ ActiveAsyncJobId = 'job1' }
            $job = @{
                Id = 'job1'; PowerShell = $ps; AsyncResult = $async; StartedAt = (Get-Date).AddMinutes(-11)
                TimeoutAt = (Get-Date).AddSeconds(-1); Status = 'running'; Result = $null
                Context = $context; Command = 'Get-Thing'
            }

            Complete-RunspaceJob -Job $job
            $runspace.Dispose()

            [PSCustomObject]@{
                Status         = $job.Status
                Message        = $job.Result.output[0].message
                ContextCleared = ($null -eq $context.ActiveAsyncJobId)
            }
        }

        $result.Status | Should -Be 'failed'
        $result.Message | Should -Be 'Command timed out'
        $result.ContextCleared | Should -BeTrue
    }

    It 'Leaves a running job alone before its timeout' {
        $status = & (Get-Module Nexus) {
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.Open()
            $ps = [PowerShell]::Create()
            $ps.Runspace = $runspace
            $null = $ps.AddScript('Start-Sleep -Seconds 30')
            $async = $ps.BeginInvoke()

            $job = @{
                Id = 'job2'; PowerShell = $ps; AsyncResult = $async; StartedAt = (Get-Date)
                TimeoutAt = (Get-Date).AddMinutes(10); Status = 'running'; Result = $null
                Context = @{}; Command = 'Get-Thing'
            }
            Complete-RunspaceJob -Job $job
            $result = $job.Status

            $ps.Stop(); $ps.Dispose(); $runspace.Dispose()
            $result
        }
        $status | Should -Be 'running'
    }
}

Describe 'Execution: Background Job Sweep' {
    # A finished job only ever advanced (and freed its context) when a client polled
    # its specific id. A closed tab / dropped connection meant nobody ever did, so the
    # context stayed locked until Nexus restarted. Sync-BackgroundJob advances every
    # running job and is called on every request, not just job polls.

    AfterEach {
        & (Get-Module Nexus) { $script:BackgroundJobs = @{} }
    }

    It 'Advances and clears a job nobody is polling by id' {
        $result = & (Get-Module Nexus) {
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.Open()
            $ps = [PowerShell]::Create()
            $ps.Runspace = $runspace
            $null = $ps.AddScript('1 + 1')
            $async = $ps.BeginInvoke()
            $null = $async.AsyncWaitHandle.WaitOne(5000)   # let it actually finish

            $context = @{ ActiveAsyncJobId = 'jobA' }
            $script:BackgroundJobs = @{
                'jobA' = @{
                    Id = 'jobA'; PowerShell = $ps; AsyncResult = $async; StartedAt = (Get-Date)
                    TimeoutAt = (Get-Date).AddMinutes(10); Status = 'running'; Result = $null
                    Context = $context; Command = 'Get-Thing'
                }
            }

            Sync-BackgroundJob   # note: never polled by id

            $runspace.Dispose()
            [PSCustomObject]@{
                Status         = $script:BackgroundJobs['jobA'].Status
                ContextCleared = ($null -eq $context.ActiveAsyncJobId)
            }
        }

        $result.Status | Should -Be 'completed'
        $result.ContextCleared | Should -BeTrue
    }

    It 'Invoke-RequestRouter calls Sync-BackgroundJob on every request' {
        $funcDef = & (Get-Module Nexus) { (Get-Command 'Invoke-RequestRouter').ScriptBlock.ToString() }
        $funcDef | Should -Match 'Sync-BackgroundJob'
    }
}

Describe 'Execution: Process Worker Launch' {
    # Start-Process joins -ArgumentList entries with a space and does NOT quote them. An
    # unquoted path containing a space (any OneDrive folder, "Program Files") therefore
    # reached pwsh split across several arguments: the worker died instantly with
    # "'C:\Users\...\OneDrive' is not recognized as the name of a script file", every
    # process-isolated module failed with "Failed to create context", and the portal
    # showed "Command not found" for all of them.

    It 'Quotes the paths it passes to the worker so a space cannot split them' {
        $captured = & (Get-Module Nexus) {
            $originalLogDir = $script:LogDir
            $script:LogDir = Join-Path ([System.IO.Path]::GetTempPath()) 'Nexus Launch Test'
            New-Item $script:LogDir -ItemType Directory -Force | Out-Null

            # Stand in for Start-Process: record the arguments and signal ready so
            # New-ProcessContext returns instead of waiting out its 60s timeout.
            $script:CapturedLaunch = $null
            function Start-Process {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                    Justification = 'Deliberate stub, removed in the finally block.')]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Signature mirrors the real call site; only ArgumentList is asserted on.')]
                param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
                $script:CapturedLaunch = $ArgumentList
                $commsDir = ($ArgumentList[-1]).Trim('"')
                'ready' | Out-File (Join-Path $commsDir 'ready') -Encoding utf8
                [PSCustomObject]@{ Id = 4242; HasExited = $false }
            }

            try {
                $entry = @{
                    name = 'SpacedModule'
                    path = Join-Path ([System.IO.Path]::GetTempPath()) 'Spaced Module' 'Spaced Module.psd1'
                }
                $null = New-ProcessContext -ModuleEntry ([PSCustomObject]$entry)

                [PSCustomObject]@{
                    Arguments  = $script:CapturedLaunch
                    WorkerPath = Join-Path $script:NexusRoot 'Workers' 'ProcessWorker.ps1'
                    ModulePath = $entry.path
                    CommsDir   = Join-Path $script:LogDir 'process_SpacedModule'
                }
            } finally {
                Remove-Item $script:LogDir -Recurse -Force -ErrorAction SilentlyContinue
                $script:ModuleRunspaces.Remove('SpacedModule')
                $script:LogDir = $originalLogDir
                Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
            }
        }

        $captured.Arguments | Should -Not -BeNullOrEmpty

        # Re-split the command line the way the child process would see it, so this
        # asserts the paths actually survive as single arguments — not just that the
        # source happens to contain quote characters.
        $commandLine = $captured.Arguments -join ' '
        $parsed = @([regex]::Matches($commandLine, '"([^"]*)"|(\S+)') | ForEach-Object {
            if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
        })

        $parsed[[array]::IndexOf($parsed, '-File') + 1]       | Should -Be $captured.WorkerPath
        $parsed[[array]::IndexOf($parsed, '-ModulePath') + 1] | Should -Be $captured.ModulePath
        $parsed[[array]::IndexOf($parsed, '-CommsDir') + 1]   | Should -Be $captured.CommsDir
    }
}

Describe 'Atomic file handoff' {
    # The process channel polls command.json/response.json; a reader must never see a
    # half-written file.

    It 'Writes the full content and leaves no temp file behind' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "NexusAtomic_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $path = Join-Path $dir 'response.json'
            & (Get-Module Nexus) { param($p) Write-AtomicFile -Path $p -Value '{"a":1}' } $path
            & (Get-Module Nexus) { param($p) Write-AtomicFile -Path $p -Value '{"a":2}' } $path

            Get-Content $path -Raw | Should -Be '{"a":2}'
            @(Get-ChildItem $dir -Filter '*.tmp').Count | Should -Be 0
        } finally {
            Remove-Item $dir -Recurse -Force
        }
    }

    It 'Writes UTF-8 without a BOM' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "NexusAtomic_$([guid]::NewGuid().ToString('N')).json"
        try {
            & (Get-Module Nexus) { param($p) Write-AtomicFile -Path $p -Value 'x' } $path
            [System.IO.File]::ReadAllBytes($path)[0] | Should -Be ([byte][char]'x')
        } finally {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'The worker never writes its channel files with Out-File' {
        $worker = Join-Path $PSScriptRoot '..' 'Workers' 'ProcessWorker.ps1'
        Get-Content $worker -Raw | Should -Not -Match 'Out-File'
    }
}

Describe 'Execution: Parameter Conversion' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Fixtures' 'FixtureModule' 'FixtureModule.psd1') -Force
        $script:JoinCmd = Get-Command Join-FixtureList -Module FixtureModule
        $script:ValueCmd = Get-Command Get-FixtureValue -Module FixtureModule
    }
    AfterAll { Remove-Module FixtureModule -ErrorAction SilentlyContinue }

    It 'Splits comma-separated text for array parameters' {
        $bound = & (Get-Module Nexus) { param($c) ConvertTo-BoundParameter -Command $c -Parameters @{ Items = 'a, b ,c'; Numbers = '1,2' } } $script:JoinCmd
        $bound.Items | Should -Be @('a', 'b', 'c')
        $bound.Numbers | Should -Be @('1', '2')
    }

    It 'Keeps a JSON array as an array' {
        $bound = & (Get-Module Nexus) { param($c) ConvertTo-BoundParameter -Command $c -Parameters @{ Items = @('x', 'y') } } $script:JoinCmd
        $bound.Items | Should -Be @('x', 'y')
    }

    It 'Treats "false" as false for [bool] and [switch]' {
        $bound = & (Get-Module Nexus) { param($c) ConvertTo-BoundParameter -Command $c -Parameters @{ Flag = 'false' } } $script:JoinCmd
        $bound.Flag | Should -BeFalse
        $bound = & (Get-Module Nexus) { param($c) ConvertTo-BoundParameter -Command $c -Parameters @{ Loud = 'False' } } $script:ValueCmd
        $bound.Loud | Should -BeFalse
    }

    It 'Drops blank values instead of binding empty strings' {
        $bound = & (Get-Module Nexus) { param($c) ConvertTo-BoundParameter -Command $c -Parameters @{ Items = '  '; Top = '' } } $script:JoinCmd
        $bound.Count | Should -Be 0
    }

    It 'Rejects a parameter the command does not declare' {
        { & (Get-Module Nexus) { param($c) ConvertTo-BoundParameter -Command $c -Parameters @{ Nope = 1 } } $script:JoinCmd } |
            Should -Throw '*not valid*'
    }

    It 'Produces values the binder accepts end to end' {
        $bound = & (Get-Module Nexus) { param($c) ConvertTo-BoundParameter -Command $c -Parameters @{ Items = 'a,b'; Numbers = '2, 3'; Flag = 'true'; Top = '4' } } $script:JoinCmd
        Join-FixtureList @bound | Should -Be 'items=a|b;numbers=5;flag=True;top=5'
    }
}

Describe 'Execution: Structured Output' {

    It 'Adds a flat data map for objects' {
        $out = & (Get-Module Nexus) { ConvertTo-HubOutput -Records @([PSCustomObject]@{ Name = 'a'; Count = 3; When = [datetime]'2026-01-02T03:04:05Z' }) }
        $out[0].stream | Should -Be 'Success'
        $out[0].data.Name | Should -Be 'a'
        $out[0].data.Count | Should -Be 3
        $out[0].data.When | Should -Match '^2026-01-02T'
        $out[0].message | Should -Match '^Name=a; Count=3; When=2026'
    }

    It 'Leaves text and numbers without data' {
        $out = & (Get-Module Nexus) { ConvertTo-HubOutput -Records @('text', 42) }
        $out | ForEach-Object { $_.PSObject.Properties.Name | Should -Not -Contain 'data' }
    }

    It 'Uses dictionary keys as columns' {
        $out = & (Get-Module Nexus) { ConvertTo-HubOutput -Records @(@{ Upn = 'x@y'; Licensed = $true }) }
        $out[0].data.Upn | Should -Be 'x@y'
        $out[0].data.Licensed | Should -BeTrue
    }

    It 'Flattens collection values into one cell' {
        $out = & (Get-Module Nexus) { ConvertTo-HubOutput -Records @([PSCustomObject]@{ Tags = @('a', 'b') }) }
        $out[0].data.Tags | Should -Be 'a; b'
    }

    It 'Uses the display property set when the type declares one' {
        $obj = [PSCustomObject]@{ Name = 'a'; Id = 1; Secret = 'hidden'; Extra = 'x' }
        $set = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('Name', 'Id'))
        $obj | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@($set))

        $out = & (Get-Module Nexus) { param($o) ConvertTo-HubOutput -Records @($o) } $obj
        @($out[0].data.Keys) | Should -Be @('Name', 'Id')
    }
}

Describe 'Execution: Process Worker End To End' {
    # Runs the real worker in a child pwsh, so the file channel, binder and output
    # shaping are exercised across the process boundary — not stubbed.

    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestRegistry.ps1')
        $script:TestRegistry = Enter-TestRegistry -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
        $script:Entry = [PSCustomObject]@{
            name = 'FixtureModule'; enabled = $true; isolation = 'process'
            path = (Join-Path $PSScriptRoot 'Fixtures' 'FixtureModule' 'FixtureModule.psd1')
        }
    }

    AfterAll {
        & (Get-Module Nexus) { Stop-ModuleContext }
        Exit-TestRegistry -Context $script:TestRegistry
    }

    It 'Returns table data from an object command' {
        $result = & (Get-Module Nexus) { param($e) Invoke-InRunspace -ModuleEntry $e -CommandName 'Get-FixtureObject' } $script:Entry
        $result.success | Should -BeTrue
        @($result.output).Count | Should -Be 2
        $result.output[1].data.Name | Should -Be 'beta'
        $result.output[1].data.Enabled | Should -BeFalse
    }

    It 'Converts typed parameters in the worker' {
        $result = & (Get-Module Nexus) { param($e) Invoke-InRunspace -ModuleEntry $e -CommandName 'Join-FixtureList' -Parameters @{ Items = 'a, b'; Flag = 'false'; Top = '1' } } $script:Entry
        $result.success | Should -BeTrue
        $result.output[0].message | Should -Be 'items=a|b;numbers=0;flag=False;top=2'
    }

    It 'Reports an error record as a failure' {
        $result = & (Get-Module Nexus) { param($e) Invoke-InRunspace -ModuleEntry $e -CommandName 'Write-FixtureFailure' } $script:Entry
        $result.success | Should -BeFalse
    }
}
