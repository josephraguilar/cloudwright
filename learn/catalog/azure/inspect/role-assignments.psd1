@{
    Id      = 'azure.inspect.role-assignments'
    Title   = 'Who has access to a resource group'
    Summary = 'Lists RBAC role assignments at a resource group, including ones inherited from the subscription and management group.'
    Learn   = @(
        'Azure RBAC is additive. A user with Owner on the subscription has Owner on every group inside it; this list shows that as an inherited assignment.'
        'Scope is the resource ID prefix. Assignments at a wider scope apply to everything below.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Resources'); Roles = @('Reader (Microsoft.Authorization/roleAssignments/read)') }
    Prerequisites = @('azure.context.set-subscription')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title = 'List role assignments'
            What  = 'Every assignment that applies at this group, direct or inherited.'
            Why   = 'Access reviews start here.'
            Raw   = @('Get-AzRoleAssignment -ResourceGroupName {{ResourceGroupName}} | Sort-Object RoleDefinitionName, DisplayName | Format-Table DisplayName, ObjectType, RoleDefinitionName, Scope -AutoSize')
        }
    )
    Docs   = @('https://learn.microsoft.com/powershell/module/az.resources/get-azroleassignment')
    Status = 'Untested'
}
