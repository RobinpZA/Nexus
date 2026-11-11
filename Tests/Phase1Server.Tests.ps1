BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Nexus.psd1') -Force
    $script:Module = Get-Module Nexus
    $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) "NexusP1_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:Temp -Force | Out-Null
    # Redirect settings and logs away from the real data root.
    $script:Original = & $script:Module { @{ Settings = $script:SettingsFile; LogDir = $script:LogDir } }
    $logDir = Join-Path $script:Temp 'Logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    & $script:Module { param($d) $script:LogDir = $d } $logDir
}

AfterAll {
    & $script:Module { param($o) $script:SettingsFile = $o.Settings; $script:LogDir = $o.LogDir } $script:Original
    Remove-Item -Path $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Read-HubSettings robustness' {
    BeforeEach {
        $script:SettingsPath = Join-Path $script:Temp "settings_$([guid]::NewGuid().ToString('N')).json"
        & $script:Module { param($p) $script:SettingsFile = $p } $script:SettingsPath
    }

    It 'Backfills missing keys from a partial file and keeps extra keys' {
        '{ "theme": "light", "customKey": 42 }' | Set-Content -Path $script:SettingsPath -Encoding utf8
        $s = & $script:Module { Read-HubSettings }
        $s.theme | Should -Be 'light'
        $s.customKey | Should -Be 42
        $s.portRange | Should -Be @(8090, 8099)
        $s.scanDepth | Should -Be 2
        $s.maxRecentCommands | Should -Be 20
    }

    It 'Returns defaults and keeps a .corrupt- backup for an unparseable file' {
        '{ not json' | Set-Content -Path $script:SettingsPath -Encoding utf8
        $s = & $script:Module { Read-HubSettings }
        $s.theme | Should -Be 'dark'
        $s.maxRecentCommands | Should -Be 20
        $backups = @(Get-ChildItem -Path $script:Temp -Filter "$(Split-Path $script:SettingsPath -Leaf).corrupt-*")
        $backups.Count | Should -Be 1
        Get-Content -Path $backups[0].FullName -Raw | Should -Match 'not json'
    }
}

Describe 'Write-ErrorResponse' {
    It 'Does not throw when the response can no longer be written' {
        $ctx = [System.Runtime.CompilerServices.RuntimeHelpers]::GetUninitializedObject([System.Net.HttpListenerContext])
        $threw = & $script:Module {
            param($c)
            function Write-JsonResponse { param($Context, $Data, $StatusCode) $null = $Context, $Data, $StatusCode; throw [System.ObjectDisposedException]::new('response') }
            try { Write-ErrorResponse -Context $c -StatusCode 500 -Message 'x'; $false } catch { $true }
        } $ctx
        $threw | Should -BeFalse
    }
}
