@{
    Id      = 'azure.identity.new-user-assigned-identity'
    Title   = 'Create a user-assigned managed identity'
    Summary = 'An identity that is its own resource, so several VMs, runbooks, or Image Builder templates can share it and it survives any one of them being deleted.'
    Learn   = @(
        'System-assigned identities live and die with one resource. User-assigned ones are standalone and reusable. Use user-assigned for anything you will rebuild.'
        'Creating it grants nothing. Assign it roles (next task) and attach it to resources.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.ManagedServiceIdentity'); Roles = @('Contributor on the resource group') }
    Prerequisites = @('azure.create.resource-group')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'IdentityName'; Label = 'Identity name'; Help = 'A user-assigned managed identity: an Entra service principal that lives as its own Azure resource, so several VMs, runbooks, or Image Builder templates can share it and it survives any one of them being deleted. System-assigned identities, by contrast, are created and deleted with a single resource.'; Type = 'String'; Required = $true; Example = 'id-avd-imagebuilder' }
    )
    Steps = @(
        @{
            Title      = 'Create the identity'
            What       = 'Creates the managed identity resource and its service principal.'
            Why        = 'Needed by Image Builder, and by anything that should authenticate without a secret.'
            Cmdlet     = 'New-AzUserAssignedIdentity'
            Parameters = @{ Name = '{{IdentityName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}' }
        }
    )
    Verify   = @('Get-AzUserAssignedIdentity -Name {{IdentityName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, PrincipalId, ClientId')
    Rollback = @('Remove-AzUserAssignedIdentity -Name {{IdentityName}} -ResourceGroupName {{ResourceGroupName}}')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.managedserviceidentity/new-azuserassignedidentity')
    Status   = 'Untested'
}
