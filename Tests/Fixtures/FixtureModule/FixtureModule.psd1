@{
    RootModule        = 'FixtureModule.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b0f4a1d2-6c3e-4a1b-9f52-7d8e0c1a4b63'
    Author            = 'Robin Pieterse'
    CompanyName       = 'Turrito Networks'
    Description       = 'Test fixture module for the Nexus suite.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Get-FixtureValue', 'Get-FixtureContext', 'Write-FixtureFailure')
    CmdletsToExport   = @()
    AliasesToExport   = @()
}
