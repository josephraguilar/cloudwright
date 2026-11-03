@{
    RootModule        = 'MsScripter.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5f1c7f0e-3b7a-4e4d-9c2a-6d1b2e8a9f10'
    Author            = 'Cloudwright contributors'
    Description       = 'Builds Microsoft admin scripts (Azure, Microsoft 365, Entra ID) for review. Never runs them.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-MsTaskCatalog'
        'Get-MsTask'
        'Test-MsTaskDefinition'
        'New-MsScript'
        'Show-MsScripter'
        'Show-MsScripterWindow'
        'Set-MsContosoMode'
        'Get-MsContosoMode'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Azure', 'Microsoft365', 'Graph', 'ScriptBuilder', 'Learning')
        }
    }
}
