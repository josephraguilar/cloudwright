@{
    Id      = 'azure.inspect.list-resources'
    Title   = 'List everything in a resource group'
    Summary = 'One table of every resource in a group with its type and region. Run it before you delete a group, and after a build to see what was created.'
    Learn   = @(
        'Get-AzResource is the generic list. Type-specific cmdlets (Get-AzVM, Get-AzStorageAccount) return richer objects.'
        'ResourceType reads provider/type, e.g. Microsoft.Compute/virtualMachines. That is the same string you see in Bicep and ARM.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Resources'); Roles = @('Reader on the resource group') }
    Prerequisites = @('azure.context.set-subscription')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title = 'List resources'
            What  = 'Reads every resource in the group and prints name, type, and location.'
            Why   = 'Cheapest way to see what a group holds.'
            Raw   = @('Get-AzResource -ResourceGroupName {{ResourceGroupName}} | Sort-Object ResourceType, Name | Format-Table Name, ResourceType, Location -AutoSize')
        }
    )
    Docs   = @('https://learn.microsoft.com/powershell/module/az.resources/get-azresource')
    Status = 'Untested'
}
