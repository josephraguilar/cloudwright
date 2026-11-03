@{
    Id      = 'azure.keyvault.new-key-vault'
    Title   = 'Create a Key Vault'
    Summary = 'A vault for secrets, keys, and certificates with RBAC authorisation and purge protection on. Scripts and runbooks read secrets from here instead of a person typing them.'
    Learn   = @(
        'RBAC authorisation (instead of access policies) is the current model: grant Key Vault Secrets User / Officer roles like any other Azure role.'
        'Purge protection cannot be turned off once on. Soft delete (default 90 days) plus purge protection means a deleted vault or secret can always be recovered within the window.'
        'The vault name is a global DNS label: 3-24 alphanumerics and hyphens.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.KeyVault'); Roles = @('Contributor on the resource group') }
    Prerequisites = @('azure.create.resource-group')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'VaultName'; Label = 'Vault name (3-24 chars, globally unique)'; Help = 'A Recovery Services vault is the container Azure Backup stores restore points and policies in. One per region is typical; it must be in the same region as the VMs and shares it protects. It cannot be deleted while it still holds protected items.'; Type = 'String'; Required = $true; Pattern = '^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$'; Example = 'kv-avd-lab-01' }
        @{ Name = 'Sku'; Label = 'SKU'; Help = 'Standard stores keys in software. Premium adds HSM-backed (hardware security module) keys for compliance regimes that require it. Secrets and certificates behave the same in both.'; Type = 'Choice'; Required = $true; Default = 'Standard'; Options = @('Standard', 'Premium') }
        @{ Name = 'RbacAuthorization'; Label = 'Use Azure RBAC for data-plane access (recommended)'; Help = 'Key Vault has two permission models. Legacy access policies are per-vault lists edited inside the vault. Azure RBAC uses normal role assignments (Key Vault Secrets User, Key Vault Secrets Officer, Key Vault Administrator) at vault or secret scope, inherited like any other role. RBAC is the recommended model and the one these tasks assume.'; Type = 'Bool'; Required = $false; Default = $true }
        @{ Name = 'PurgeProtection'; Label = 'Purge protection (cannot be turned off later)'; Help = 'Soft delete keeps deleted vaults and secrets recoverable for 7 to 90 days. Purge protection additionally forbids permanently deleting (purging) them during that window, even for an administrator. Required by some compliance baselines; cannot be turned off once on, and the vault name stays reserved until the window ends.'; Type = 'Bool'; Required = $false; Default = $true }
    )
    Steps = @(
        @{
            Title      = 'Create the vault'
            What       = 'Creates the vault with RBAC authorisation and purge protection.'
            Why        = 'Both are hard or impossible to retrofit cleanly.'
            Cmdlet     = 'New-AzKeyVault'
            Parameters = @{ Name = '{{VaultName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}'; Sku = '{{Sku}}'; EnableRbacAuthorization = '{{RbacAuthorization}}'; EnablePurgeProtection = '{{PurgeProtection}}' }
            ParameterOrder = @('Name', 'ResourceGroupName', 'Location', 'Sku', 'EnableRbacAuthorization', 'EnablePurgeProtection')
        }
    )
    Verify   = @('Get-AzKeyVault -VaultName {{VaultName}} | Select-Object VaultName, Location, Sku, EnableRbacAuthorization, EnablePurgeProtection, VaultUri')
    Rollback = @('Remove-AzKeyVault -VaultName {{VaultName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Soft-deleted; the name stays reserved for 90 days.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.keyvault/new-azkeyvault')
    Status   = 'Untested'
}
