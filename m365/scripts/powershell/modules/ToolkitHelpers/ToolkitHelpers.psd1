@{
    RootModule        = 'ToolkitHelpers.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e5a7b9c1-3d2f-4e6a-8b0c-9d1e2f3a4b5c'
    Author            = 'Cloudwright contributors'
    Description       = 'The toolkit about itself: discovers task scripts and their parameters, classifies read-only vs write, composes command lines. Drives the GUI task view and the console catalog menu.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-M365Task'
        'Get-M365TaskArea'
        'Format-M365Argument'
        'Format-M365CommandLine'
        'ConvertTo-M365TaskValue'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Toolkit', 'Catalog') } }
}
