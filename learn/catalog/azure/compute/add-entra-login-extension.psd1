@{
    Id      = 'azure.compute.add-entra-login-extension'
    Title   = 'Enable Entra ID sign-in on a Windows VM'
    Summary = 'Turns on the system-assigned identity, installs the AADLoginForWindows extension, and grants a group the Virtual Machine User Login role. Users then RDP with their Entra account.'
    Learn   = @(
        'Three things, in order: the VM needs a managed identity (the extension uses it to register the device), then the extension, then RBAC. Without the role assignment users get "no permission" at logon.'
        'Virtual Machine Administrator Login gives local admin; Virtual Machine User Login does not. Scope it to the VM, not the subscription.'
        'Clients that are not themselves Entra joined need the RDP file property targetisaadjoined:i:1 (AVD sets this on the host pool).'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute', 'Az.Resources'); Roles = @('Virtual Machine Contributor + User Access Administrator on the VM') }
    Prerequisites = @('azure.compute.new-vm-windows')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'Virtual machine'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVM'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region (same as the VM)'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'GroupObjectId'; Label = 'Entra group allowed to sign in'; Help = 'The Entra group''s object ID (a GUID), which is what Azure RBAC stores; the list shows display names and writes the ID. Assign roles to groups rather than users so access changes are a membership change, not an Azure change.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzADGroup'; Display = 'DisplayName'; Value = 'Id'; Auth = 'Azure' } }
        @{ Name = 'Role'; Label = 'Role'; Help = 'Virtual Machine User Login = can sign in and gets a standard user session. Virtual Machine Administrator Login = sign in with local administrator rights. These are Azure RBAC roles on the VM resource, checked at Windows logon when the VM is Entra joined.'; Type = 'Choice'; Required = $true; Default = 'Virtual Machine User Login'; Options = @('Virtual Machine User Login', 'Virtual Machine Administrator Login') }
        @{ Name = 'ExtensionVersion'; Label = 'AADLoginForWindows extension version'; Help = 'Major.minor version of the AADLoginForWindows extension handler. 2.0 is current. Azure picks the latest patch within that minor. Check the extension documentation before changing.'; Type = 'String'; Required = $true; Default = '2.0'; Pattern = '^\d+\.\d+$' }
    )
    Steps = @(
        @{
            Title = 'Turn on the system-assigned identity'
            What  = 'Updates the VM with IdentityType SystemAssigned.'
            Why   = 'The extension registers the VM in Entra using this identity.'
            Fixed = @('IdentityType')
            Raw   = @('Update-AzVM -ResourceGroupName {{ResourceGroupName}} -VM (Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}}) -IdentityType SystemAssigned')
        }
        @{
            Title      = 'Install the AADLoginForWindows extension'
            What       = 'Joins the VM to Entra ID and enables Entra credentials at the Windows logon screen.'
            Why        = 'Same extension the azure repo''s Join-AvdSessionHost uses for Entra joined hosts.'
            Cmdlet     = 'Set-AzVMExtension'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; VMName = '{{VMName}}'; Location = '{{Location}}'; Name = '''AADLoginForWindows'''; Publisher = '''Microsoft.Azure.ActiveDirectory'''; ExtensionType = '''AADLoginForWindows'''; TypeHandlerVersion = '{{ExtensionVersion}}' }
            ParameterOrder = @('ResourceGroupName', 'VMName', 'Location', 'Name', 'Publisher', 'ExtensionType', 'TypeHandlerVersion')
            Fixed          = @('Name', 'Publisher', 'ExtensionType')
        }
        @{
            Title = 'Grant the group sign-in rights on the VM'
            What  = 'Role assignment scoped to the VM resource ID.'
            Why   = 'Entra join alone does not let anyone log on. RBAC decides who.'
            Raw   = @('New-AzRoleAssignment -ObjectId {{GroupObjectId}} -RoleDefinitionName {{Role}} -Scope (Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}}).Id')
        }
    )
    Verify   = @('Get-AzVMExtension -ResourceGroupName {{ResourceGroupName}} -VMName {{VMName}} -Name ''AADLoginForWindows'' | Select-Object Name, ProvisioningState', 'Get-AzRoleAssignment -Scope (Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}}).Id | Format-Table DisplayName, RoleDefinitionName')
    Rollback = @('Remove-AzRoleAssignment -ObjectId {{GroupObjectId}} -RoleDefinitionName {{Role}} -Scope (Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}}).Id', 'Remove-AzVMExtension -ResourceGroupName {{ResourceGroupName}} -VMName {{VMName}} -Name ''AADLoginForWindows'' -Force')
    Docs     = @('https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-windows', 'https://learn.microsoft.com/powershell/module/az.compute/set-azvmextension')
    Status   = 'Untested'
}
