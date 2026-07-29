@{
    RootModule        = 'FakeGraphModule.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'c4e1f7a8-9b2d-4e63-8a15-2f6c0d3b7e91'
    Author            = 'Robin Pieterse'
    CompanyName       = 'Turrito Networks'
    Description       = 'Test fixture that mimics a Graph-connected module.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Connect-FakeGraph', 'Get-MgContext', 'Disconnect-MgGraph')
    CmdletsToExport   = @()
    AliasesToExport   = @()
}
