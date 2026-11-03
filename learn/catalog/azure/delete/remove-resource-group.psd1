@{
    Id      = 'azure.delete.remove-resource-group'
    Title   = 'Delete a resource group and everything in it'
    Summary = 'Lists what is inside first, then deletes the group. There is no undo. Vaults with protected items and locked resources will block it, which is the point of locks.'
    Learn   = @(
        'Run the list step and read it. The delete is asynchronous and removes resources in dependency order; it can take many minutes.'
        'Soft-deleted things (Key Vaults, storage shares, Log Analytics workspaces) keep their names reserved for days after the group is gone.'
        'Put a CanNotDelete lock on groups that must never be removed this way: New-AzResourceLock.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Resources'); Roles = @('Contributor on the resource group (Owner if locks exist)') }
    Prerequisites = @('azure.inspect.list-resources')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group to delete'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title = 'See what you are about to delete'
            What  = 'Lists every resource in the group.'
            Why   = 'The one chance to notice the production database sitting in the lab group.'
            Raw   = @('Get-AzResource -ResourceGroupName {{ResourceGroupName}} | Format-Table Name, ResourceType -AutoSize')
        }
        @{
            Title      = 'Delete the group'
            What       = 'Deletes the group and all its resources.'
            Why        = 'Run it only after reading the list above.'
            Cmdlet     = 'Remove-AzResourceGroup'
            Parameters = @{ Name = '{{ResourceGroupName}}'; Force = '$true' }
            Fixed      = @('Force')
        }
    )
    Verify = @('Get-AzResourceGroup -Name {{ResourceGroupName}} -ErrorAction SilentlyContinue    # Nothing back means it is gone')
    Docs   = @('https://learn.microsoft.com/powershell/module/az.resources/remove-azresourcegroup')
    Status = 'Untested'
}
