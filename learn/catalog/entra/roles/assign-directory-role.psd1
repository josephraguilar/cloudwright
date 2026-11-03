@{
    Id      = 'entra.roles.assign-directory-role'
    Title   = 'Assign an Entra admin role (permanent)'
    Summary = 'Adds a user as a permanent member of a directory role such as Helpdesk Administrator. For anything above that, use PIM eligible assignments instead.'
    Learn   = @(
        'Permanent assignments are what attackers look for. PIM (Entra ID P2) makes them just-in-time; this task is for tenants without P2 or for low-impact roles.'
        'Built-in roles exist as templates until first used; New-MgDirectoryRole -RoleTemplateId activates one. The step handles both cases by activating if needed.'
        'Global Administrator should have two to four members, all with MFA and a break-glass account excluded from Conditional Access.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Users'); Scopes = @('RoleManagement.ReadWrite.Directory'); Roles = @('Privileged Role Administrator') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'RoleName'; Label = 'Role'; Help = 'An Entra directory role (not Azure RBAC): Global Administrator, User Administrator, Helpdesk Administrator, Exchange Administrator and so on. This task makes a permanent, always-active assignment. With Entra ID P2, Privileged Identity Management (PIM) can make roles eligible instead, activated for a few hours with MFA and a reason; prefer that for anything above helpdesk level.'; Type = 'Choice'; Required = $true; Default = 'Helpdesk Administrator'
           Source = @{ Cmdlet = 'Get-MgDirectoryRoleTemplate'; Display = 'DisplayName'; Value = 'DisplayName'; Auth = 'Graph' } }
        @{ Name = 'UserId'; Label = 'User'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title = 'Activate the role from its template if this is its first use'
            What  = 'Creates the directoryRole object for the template when no active role with that name exists yet.'
            Why   = 'Roles nobody has used are not instantiated; adding a member to a missing role fails.'
            Raw   = @('if (-not (Get-MgDirectoryRole -Filter {{RoleName:filter:displayName}})) { New-MgDirectoryRole -RoleTemplateId (Get-MgDirectoryRoleTemplate | Where-Object DisplayName -eq {{RoleName}}).Id }')
        }
        @{
            Title = 'Add the user to the role'
            What  = 'POST /directoryRoles/{id}/members/$ref.'
            Why   = 'Takes effect at the user''s next token refresh.'
            Raw   = @('New-MgDirectoryRoleMemberByRef -DirectoryRoleId (Get-MgDirectoryRole -Filter {{RoleName:filter:displayName}}).Id -BodyParameter @{ ''@odata.id'' = "https://graph.microsoft.com/v1.0/directoryObjects/$((Get-MgUser -UserId {{UserId}}).Id)" }')
        }
    )
    Verify   = @('Get-MgDirectoryRoleMember -DirectoryRoleId (Get-MgDirectoryRole -Filter {{RoleName:filter:displayName}}).Id | Select-Object Id, @{ n = ''Member''; e = { $_.AdditionalProperties.userPrincipalName } }')
    Rollback = @('Remove-MgDirectoryRoleMemberByRef -DirectoryRoleId (Get-MgDirectoryRole -Filter {{RoleName:filter:displayName}}).Id -DirectoryObjectId (Get-MgUser -UserId {{UserId}}).Id')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.identity.directorymanagement/new-mgdirectoryrolememberbyref', 'https://learn.microsoft.com/entra/identity/role-based-access-control/permissions-reference')
    Status   = 'Untested'
}
