@{
    RootModule        = 'GdapHelpers.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'd4f6a8b0-1c2e-4f3a-9b5d-6e7f8a9b0c1d'
    Author            = 'Cloudwright contributors'
    Description       = 'Granular Delegated Admin Privileges (GDAP) over Microsoft Graph: fixed role table and template, customer tenant lookup, relationship discovery, compliance comparison, request creation and lock (with lock retry), approval polling, access assignments (create or extend), resumable state. Every change goes through Invoke-M365Change.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-GdapRoleId'
        'Get-GdapRoleName'
        'Get-GdapAdminRoleName'
        'Get-GdapRoleList'
        'Format-GdapRoleList'
        'Get-GdapTemplate'
        'Get-GdapApprovalUrl'
        'Get-GdapRequestSummary'
        'Open-GdapApprovalPage'
        'Test-GdapDuration'
        'Get-GdapTenantInfo'
        'Get-GdapCustomer'
        'Get-GdapAccessAssignment'
        'Get-GdapRelationship'
        'Compare-GdapRelationship'
        'Test-GdapCompliance'
        'New-GdapRequest'
        'Lock-GdapRelationship'
        'Wait-GdapApproval'
        'Set-GdapAccessAssignment'
        'Get-GdapState'
        'Save-GdapState'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('GDAP', 'PartnerCenter', 'Graph', 'MSP') } }
}
