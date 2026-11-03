@{
    Id      = 'azure.keyvault.set-secret'
    Title   = 'Store a secret in Key Vault'
    Summary = 'Writes a secret value. The value is typed when the script runs, never stored in this script.'
    Learn   = @(
        'Setting an existing secret name creates a new version. Old versions stay until you disable or purge them.'
        'With RBAC authorisation you need Key Vault Secrets Officer on the vault to write. Secrets User can only read.'
        'Read it back later with Get-AzKeyVaultSecret -AsPlainText, or from a runbook with the Automation account''s managed identity.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.KeyVault'); Roles = @('Key Vault Secrets Officer on the vault') }
    Prerequisites = @('azure.keyvault.new-key-vault')
    Fields = @(
        @{ Name = 'VaultName'; Label = 'Key vault'; Help = 'A Recovery Services vault is the container Azure Backup stores restore points and policies in. One per region is typical; it must be in the same region as the VMs and shares it protects. It cannot be deleted while it still holds protected items.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzKeyVault'; Display = 'VaultName'; Value = 'VaultName'; Auth = 'Azure' } }
        @{ Name = 'SecretName'; Label = 'Secret name'; Help = 'The secret name in the vault. Setting an existing name creates a new version.'; Type = 'String'; Required = $true; Pattern = '^[A-Za-z0-9-]{1,127}$'; Example = 'avd-local-admin-password' }
        @{ Name = 'SecretValue'; Label = 'Secret value'; Help = 'Not entered here. Read-Host prompts for it as a SecureString when the script runs.'; Type = 'Secret'; SecretKind = 'SecureString' }
    )
    Steps = @(
        @{
            Title      = 'Write the secret'
            What       = 'Prompts for the value as a SecureString and stores it as a new version.'
            Why        = 'The value never appears on screen or in history.'
            Cmdlet     = 'Set-AzKeyVaultSecret'
            Parameters = @{ VaultName = '{{VaultName}}'; Name = '{{SecretName}}'; SecretValue = '{{SecretValue}}' }
            ParameterOrder = @('VaultName', 'Name', 'SecretValue')
        }
    )
    Verify   = @('Get-AzKeyVaultSecret -VaultName {{VaultName}} -Name {{SecretName}} | Select-Object Name, Version, Enabled, Created')
    Rollback = @('Remove-AzKeyVaultSecret -VaultName {{VaultName}} -Name {{SecretName}} -Force    # Soft-deleted; recover with Undo-AzKeyVaultSecretRemoval.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.keyvault/set-azkeyvaultsecret')
    Status   = 'Untested'
}
