@{
    RootModule        = 'FilesAdmin.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a4d71c2e-90b8-4f53-8e6a-5c3b2d1f0e97'
    Author            = 'Cloudwright contributors'
    Description       = 'Azure Files: storage accounts and shares with usage; create an account or a share; change a share quota. No deletes.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-FilesAccountInfo'
        'Get-FilesShareInfo'
        'Test-FilesAccountName'
        'New-FilesStorageAccount'
        'New-FilesShare'
        'Set-FilesShareQuota'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Azure', 'Storage', 'Files', 'FSLogix') } }
}
