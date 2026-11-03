@{
    Id      = 'azure.identity.new-role-assignment'
    Title   = 'Grant a role to a group on a resource group'
    Summary = 'Azure RBAC: who (a group) can do what (a role) where (a scope). Assign to groups, not users, and at the narrowest scope that works.'
    Learn   = @(
        'Scope is a resource ID. A resource group scope covers everything inside it now and in future. Subscription scope covers every group.'
        'Owner and User Access Administrator can grant roles to others. Contributor can do everything except that. Reader can only look.'
        'Assignments take a minute or two to apply. A user already signed in may need a new token.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Resources'); Roles = @('Owner or User Access Administrator at the scope') }
    Prerequisites = @('azure.create.resource-group')
    Fields = @(
        @{ Name = 'GroupObjectId'; Label = 'Entra group'; Help = 'The Entra group''s object ID (a GUID), which is what Azure RBAC stores; the list shows display names and writes the ID. Assign roles to groups rather than users so access changes are a membership change, not an Azure change.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzADGroup'; Display = 'DisplayName'; Value = 'Id'; Auth = 'Azure' } }
        @{ Name = 'Role'; Label = 'Role'; Help = 'An Azure RBAC role: a named set of allowed actions. Reader = look only. Contributor = create and change anything except access. Owner = Contributor plus grant roles to others. User Access Administrator = only grant roles. Service roles (Virtual Machine Contributor, Network Contributor, Storage Blob Data Contributor) limit the blast radius; prefer them. The list comes from Get-AzRoleDefinition.'; Type = 'Choice'; Required = $true; Default = 'Reader'
           Source = @{ Cmdlet = 'Get-AzRoleDefinition'; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'ResourceGroupName'; Label = 'Resource group (scope)'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title      = 'Assign the role'
            What       = 'Creates the role assignment at resource group scope.'
            Why        = 'Group + role + scope is the whole model.'
            Cmdlet     = 'New-AzRoleAssignment'
            Parameters = @{ ObjectId = '{{GroupObjectId}}'; RoleDefinitionName = '{{Role}}'; ResourceGroupName = '{{ResourceGroupName}}' }
            ParameterOrder = @('ObjectId', 'RoleDefinitionName', 'ResourceGroupName')
        }
    )
    Verify   = @('Get-AzRoleAssignment -ObjectId {{GroupObjectId}} -ResourceGroupName {{ResourceGroupName}} | Format-Table DisplayName, RoleDefinitionName, Scope')
    Rollback = @('Remove-AzRoleAssignment -ObjectId {{GroupObjectId}} -RoleDefinitionName {{Role}} -ResourceGroupName {{ResourceGroupName}}')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.resources/new-azroleassignment')
    Status   = 'Untested'
}
