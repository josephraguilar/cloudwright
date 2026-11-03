@{
    RootModule        = 'AzHelpers.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '65f9b6da-0155-4b27-8f36-a4a4e6d53219'
    Author            = 'Cloudwright contributors'
    Description       = 'Shared helpers for the Azure administration scripts in this repo.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Assert-AzContext', 'Assert-AzResourceProvider', 'Find-AzSubscriptionAcrossTenant', 'Get-AzEffectivePermission', 'Test-AzActionAllowed', 'Get-AzDirectoryRoleMembership', 'Set-AzScriptDefault')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Azure', 'Admin')
        }
    }
}
