@{
    Id      = 'entra.apps.new-app-registration'
    Title   = 'Create an app registration and service principal'
    Summary = 'An identity for automation (runbooks, CI, a script with its own permissions). The registration is the definition; the service principal is the instance in your tenant.'
    Learn   = @(
        'Prefer a managed identity when the code runs in Azure. App registrations are for code that runs elsewhere.'
        'Credentials (certificate preferred, secret second) are added separately and expire. Put the expiry in your calendar.'
        'API permissions are granted on the service principal after this; nothing here grants access to anything.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Applications'); Scopes = @('Application.ReadWrite.All'); Roles = @('Application Administrator') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'DisplayName'; Label = 'App name'; Help = 'The human-readable name shown in portals and address lists.'; Type = 'String'; Required = $true; Example = 'automation-hudu-sync' }
        @{ Name = 'SignInAudience'; Label = 'Who can sign in'; Help = 'Which accounts can authenticate to the app. AzureADMyOrg = only accounts in this tenant (single tenant, the right default for internal automation). AzureADMultipleOrgs = accounts in any Entra tenant (multi-tenant SaaS). Options with personal Microsoft accounts exist too but are rarely wanted for admin tooling.'; Type = 'Choice'; Required = $true; Default = 'AzureADMyOrg'
           Options = @(@{ Display = 'This tenant only (AzureADMyOrg)'; Value = 'AzureADMyOrg' }, @{ Display = 'Any Entra tenant (AzureADMultipleOrgs)'; Value = 'AzureADMultipleOrgs' }) }
    )
    Steps = @(
        @{
            Title      = 'Create the application'
            What       = 'POST /applications.'
            Why        = 'Defines the app; its AppId (client ID) is what code authenticates with.'
            Cmdlet     = 'New-MgApplication'
            Parameters = @{ DisplayName = '{{DisplayName}}'; SignInAudience = '{{SignInAudience}}' }
            Output     = 'app'
        }
        @{
            Title = 'Create the service principal'
            What  = 'POST /servicePrincipals with the AppId.'
            Why   = 'Without it the app cannot be granted permissions or roles in this tenant.'
            Raw   = @('New-MgServicePrincipal -AppId (Get-MgApplication -Filter "displayName eq ''{{DisplayName:raw}}''").AppId')
        }
    )
    Verify   = @('Get-MgApplication -Filter "displayName eq ''{{DisplayName:raw}}''" | Select-Object DisplayName, AppId, Id, SignInAudience')
    Rollback = @('Remove-MgApplication -ApplicationId (Get-MgApplication -Filter "displayName eq ''{{DisplayName:raw}}''").Id    # Also removes the service principal. Soft-deleted 30 days.')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.applications/new-mgapplication')
    Status   = 'Untested'
}
