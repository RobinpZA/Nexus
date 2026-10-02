@{
    RootModule        = 'Nexus.psm1'
    ModuleVersion     = '1.2.0'
    GUID              = '86147d2b-ae69-4971-8b44-06af60f8418b'
    Author            = 'Robin Pieterse'
    CompanyName       = 'Turrito Networks'
    Description       = 'Central PowerShell module hub with embedded web portal for discovering, managing, and running custom modules.'
    PowerShellVersion = '7.2'

    FunctionsToExport = @(
        'Start-Nexus'
        'Stop-Nexus'
        'Open-Nexus'
        'Enable-NexusAutoStart'
        'Get-OpsModule'
        'Import-OpsModule'
        'Get-OpsCommand'
        'Invoke-OpsCommand'
        'Register-OpsModule'
        'Unregister-OpsModule'
        'Update-OpsRegistry'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @('ops')

    PrivateData = @{
        PSData = @{
            Tags       = @('ModuleHub', 'Launcher', 'WebPortal', 'Admin')
            ProjectUri = 'https://github.com/RobinpZA/Nexus'
        }
    }
}
