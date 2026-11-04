@{
    RootModule        = 'Cloudwright.psm1'
    ModuleVersion     = '0.2.1'
    GUID              = '7ad94ed0-8f52-40c3-9a17-6db243e8f015'
    Author            = 'Cloudwright contributors'
    Description       = 'Learn Microsoft commands and manage Azure, AVD, and Microsoft 365 from one launcher.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Start-Cloudwright')
    AliasesToExport   = @('cloudwright')
    CmdletsToExport   = @()
    VariablesToExport = @()
    PrivateData       = @{
        CloudwrightSafetyBaseline = 2
        PSData = @{
            Tags = @('Azure', 'AVD', 'Microsoft365', 'PowerShell', 'Learning')
        }
    }
}
