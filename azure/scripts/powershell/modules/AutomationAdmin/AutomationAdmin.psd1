@{
    RootModule        = 'AutomationAdmin.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '9c3f6a28-b7e4-4d15-8f0a-2e6c4b91d7a3'
    Author            = 'Cloudwright contributors'
    Description       = 'Azure Automation runbooks: accounts, runbooks, recent jobs and their output, start one (optionally waiting), import a new one. No deletes.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-RunbookAccountInfo'
        'Get-RunbookInfo'
        'Get-RunbookJobInfo'
        'Get-RunbookJobOutput'
        'Start-RunbookNow'
        'Import-RunbookFile'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Azure', 'Automation', 'Runbook') } }
}
