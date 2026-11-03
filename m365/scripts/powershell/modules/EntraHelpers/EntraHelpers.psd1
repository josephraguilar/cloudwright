@{
    RootModule        = 'EntraHelpers.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'b7d9e1f3-2a4c-4b6d-8e0f-1a2b3c4d5e6f'
    Author            = 'Cloudwright contributors'
    Description       = 'Reusable Entra ID logic over Microsoft Graph: user review, break-glass and admin accounts, role assignment, Conditional Access exclusions, technical contacts, GDAP relationships. Every change goes through Invoke-M365Change (M365Helpers).'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-M365UserReview'
        'New-M365CloudUser'
        'Add-M365RoleAssignment'
        'Add-M365ConditionalAccessExclusion'
        'New-M365BreakGlassAccount'
        'New-M365AdminAccount'
        'Set-M365TechnicalContact'
        'Get-M365GdapRelationship'
        'Get-M365LicenseSummary'
        'Disable-M365UserSignIn'
        'Remove-M365UserLicense'
        'New-M365User'
        'Add-M365UserLicense'
        'Add-M365GroupMember'
        'New-M365TemporaryAccessPass'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('EntraID', 'Graph', 'MSP') } }
}
