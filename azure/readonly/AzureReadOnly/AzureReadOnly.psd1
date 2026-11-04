@{
    RootModule        = 'AzureReadOnly.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '08441af8-c012-44bd-b68b-1e41c9c7946a'
    Author            = 'Cloudwright contributors'
    Description       = 'Read-only Azure and AVD inspection for Cloudwright safe mode: allowlisted reads only.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-AzReadCommandPolicy'
        'Get-AzReadOnlyMissingModule'
        'Connect-AzReadOnly'
        'Get-AzReadOnlySession'
        'Get-AzReadOnlySubscription'
        'Select-AzReadOnlySubscription'
        'Get-AzReadOnlyAccess'
        'Get-AzReadOnlyResourceGroup'
        'Get-AzReadOnlyVm'
        'Get-AzReadOnlyAvdEnvironment'
        'Get-AzReadOnlyHostPool'
        'Get-AzReadOnlyUserSession'
        'Get-AzReadOnlyAvdHealth'
        'Get-AzReadOnlyNetwork'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Azure', 'AVD', 'AzureVirtualDesktop', 'ReadOnly')
        }
    }
}
