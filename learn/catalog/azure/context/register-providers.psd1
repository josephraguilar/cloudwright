@{
    Id      = 'azure.context.register-providers'
    Title   = 'Register resource providers'
    Summary = 'A resource provider is the ARM back-end for a family of resource types. Each must be registered once per subscription before you can create its types.'
    Learn   = @(
        'Registration is free, idempotent, and does nothing until you create a resource. An unregistered provider fails at deploy time with a confusing error, so register the set up front.'
        'Microsoft.AAD is Entra Domain Services (managed AD DS), not Entra ID. Only register it if you use that.'
        'Needs Contributor at subscription scope. Resource-group Contributor is not enough.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Resources'); Roles = @('Contributor on the subscription') }
    Prerequisites = @('azure.context.set-subscription')
    Fields = @(
        @{
            Name     = 'Namespaces'
            Label    = 'Providers to register'
            Type     = 'MultiChoice'
            Required = $true
            Options  = @(
                'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.DesktopVirtualization',
                'Microsoft.RecoveryServices', 'Microsoft.Automation', 'Microsoft.OperationalInsights', 'Microsoft.Insights',
                'Microsoft.KeyVault', 'Microsoft.ManagedIdentity', 'Microsoft.AAD'
            )
            Help     = 'Pick everything you will need for the environment. Re-running on registered ones is a no-op.'
        }
    )
    Steps = @(
        @{
            Title = 'Register each provider'
            What  = 'Fires one registration per namespace. Returns immediately; the real work is asynchronous.'
            Why   = 'Registering all first and polling after is faster than one at a time.'
            Raw   = @('{{Namespaces}} | ForEach-Object { Register-AzResourceProvider -ProviderNamespace $_ }')
        }
    )
    Verify = @('{{Namespaces}} | ForEach-Object { Get-AzResourceProvider -ProviderNamespace $_ | Select-Object -First 1 ProviderNamespace, RegistrationState }')
    Docs   = @('https://learn.microsoft.com/powershell/module/az.resources/register-azresourceprovider')
    Status = 'Untested'
}
