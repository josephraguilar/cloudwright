@{
    RootModule        = 'EntraAdmin.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '6f2a9d41-8c3e-4b7a-a1d5-2e9f0c7b4a13'
    Author            = 'Cloudwright contributors'
    Description       = 'Entra ID users and groups through Microsoft Graph with the Az sign-in: list, create, add to group, block or allow sign-in, reset password, revoke sessions, assign a licence. No deletes.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Invoke-EntraGraph'
        'New-EntraPassword'
        'Get-EntraDomainInfo'
        'Get-EntraLicenseInfo'
        'Get-EntraUserInfo'
        'Get-EntraUserGroupInfo'
        'Resolve-EntraUser'
        'Get-EntraGroupInfo'
        'Get-EntraGroupMemberInfo'
        'New-EntraUser'
        'New-EntraGroup'
        'Add-EntraGroupMember'
        'Set-EntraUserSignIn'
        'Reset-EntraUserPassword'
        'Revoke-EntraUserSession'
        'Add-EntraUserLicense'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Azure', 'Entra', 'Graph', 'Users', 'Groups') } }
}
