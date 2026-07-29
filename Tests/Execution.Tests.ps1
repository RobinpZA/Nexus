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
