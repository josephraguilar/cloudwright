@{
    Id      = 'azure.avd.grant-desktop-access'
    Title   = 'Grant a group access to the desktop'
    Summary = 'Assigns Desktop Virtualization User on the application group. That role, on that object, is what makes the desktop appear for the user.'
    Learn   = @(
        'Scope is the app group, not the host pool or resource group. Granting it wider works but exposes every app group underneath.'
        'For Entra-joined hosts the same group also needs Virtual Machine User Login on the VMs (the session host task does that).'
        'Assign groups, never individual users. Membership changes then need no Azure change.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Resources', 'Az.DesktopVirtualization'); Roles = @('User Access Administrator on the resource group') }
    Prerequisites = @('azure.avd.new-application-group')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'AppGroupName'; Label = 'Application group'; Help = 'The AVD application group: the object users are granted access to (Desktop Virtualization User role on it). A host pool has one Desktop app group and optionally several RemoteApp groups. The portal default name is <hostpool>-DAG for the desktop group.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdApplicationGroup'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'GroupObjectId'; Label = 'Entra group of users'; Help = 'The Entra group''s object ID (a GUID), which is what Azure RBAC stores; the list shows display names and writes the ID. Assign roles to groups rather than users so access changes are a membership change, not an Azure change.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzADGroup'; Display = 'DisplayName'; Value = 'Id'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title = 'Assign Desktop Virtualization User on the app group'
            What  = 'Role assignment scoped to the application group resource ID.'
            Why   = 'This is the AVD "publish to users" step.'
            Fixed = @('RoleDefinitionName')
            Raw   = @('New-AzRoleAssignment -ObjectId {{GroupObjectId}} -RoleDefinitionName ''Desktop Virtualization User'' -Scope (Get-AzWvdApplicationGroup -Name {{AppGroupName}} -ResourceGroupName {{ResourceGroupName}}).Id')
        }
    )
    Verify   = @('Get-AzRoleAssignment -Scope (Get-AzWvdApplicationGroup -Name {{AppGroupName}} -ResourceGroupName {{ResourceGroupName}}).Id | Format-Table DisplayName, RoleDefinitionName')
    Rollback = @('Remove-AzRoleAssignment -ObjectId {{GroupObjectId}} -RoleDefinitionName ''Desktop Virtualization User'' -Scope (Get-AzWvdApplicationGroup -Name {{AppGroupName}} -ResourceGroupName {{ResourceGroupName}}).Id')
    Docs     = @('https://learn.microsoft.com/azure/virtual-desktop/manage-app-groups')
    Status   = 'Untested'
}
