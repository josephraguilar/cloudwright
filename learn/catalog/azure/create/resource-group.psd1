@{
    Id      = 'azure.create.resource-group'
    Title   = 'Create a resource group'
    Summary = 'A resource group is a lifecycle, RBAC, and cost boundary. Delete it and everything inside goes with it.'
    Learn   = @(
        'It is NOT a network, identity, or reference boundary. A VM in one group can use a subnet in another with nothing extra configured.'
        'Decide the split before building. Moving resources between groups later works for most types but is never pleasant.'
        'The group has a region of its own. That only decides where its metadata lives; resources inside can be anywhere.'
    )
    Requires = @{
        Auth    = 'Azure'
        Modules = @('Az.Resources')
        Roles   = @('Contributor on the subscription (or Owner)')
    }
    Prerequisites = @('azure.context.set-subscription')
    Fields = @(
        @{
            Name     = 'Name'
            Label    = 'Resource group name'
            Type     = 'String'
            Required = $true
            Pattern  = '^[-\w\.\(\)]{1,90}$'
            Help     = '1 to 90 characters. Letters, digits, underscore, hyphen, period, parentheses. Cannot end in a period.'
            Example  = 'rg-avd-lab'
        }
        @{
            Name     = 'Location'
            Label    = 'Region'
            Type     = 'Choice'
            Required = $true
            Default  = 'eastus2'
            Help     = 'Short name, e.g. eastus2, westus3, centralus. Sign in to pick from the live list.'
            Source   = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' }
        }
        @{
            Name     = 'Tags'
            Label    = 'Tags (key=value, comma separated, blank for none)'
            Type     = 'Hashtable'
            Required = $false
            Example  = 'env=lab, owner=jane'
            Help     = 'Tags on the group are not inherited by resources inside it unless an Azure Policy copies them.'
        }
    )
    Steps = @(
        @{
            Title      = 'Create the resource group'
            What       = 'One ARM call. Idempotent: running it again for an existing group with the same name and region is a no-op.'
            Why        = 'Every other Azure resource needs a group to live in, so this is step one of almost every build.'
            Cmdlet     = 'New-AzResourceGroup'
            Parameters = @{ Name = '{{Name}}'; Location = '{{Location}}'; Tag = '{{Tags}}' }
            Output     = 'rg'
        }
    )
    Verify   = @('Get-AzResourceGroup -Name {{Name}} | Format-List ResourceGroupName, Location, ProvisioningState, Tags')
    Rollback = @('Remove-AzResourceGroup -Name {{Name}} -Force    # Deletes EVERYTHING in the group. No undo.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.resources/new-azresourcegroup')
    Status   = 'Untested'
}
