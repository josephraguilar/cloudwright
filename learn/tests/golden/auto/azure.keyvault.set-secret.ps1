Set-AzKeyVaultSecret -VaultName 'sample-vaultname' -Name 'avd-local-admin-password' -SecretValue (Read-Host -Prompt 'Secret value' -AsSecureString)
