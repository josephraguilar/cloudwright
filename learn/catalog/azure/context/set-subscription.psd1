@{
    Id      = 'azure.context.set-subscription'
    Title   = 'Sign in and select a subscription'
    Summary = 'Every Az cmdlet runs against the current context: one account, one tenant, one subscription. Set it on purpose.'
    Learn   = @(
        'Connect-AzAccount opens a browser or Windows sign-in. The token is cached, so you sign in once per machine, not once per script.'
        'An account can see many subscriptions across many tenants. Get-AzSubscription lists them; Set-AzContext picks one.'
        'Scripts in the azure repo call Assert-AzContext for this. It is the same two cmdlets with an "already signed in?" check.'
    )
    Requires = @{
        Auth    = 'None'
        Modules = @('Az.Accounts')
        Roles   = @('Reader on at least one subscription')
    }
    Fields = @(
        @{
            Name     = 'TenantId'
            Label    = 'Tenant ID (blank to use the account default)'
            Help     = 'The Entra tenant (directory) GUID, or a verified domain like contoso.onmicrosoft.com. One account can be a member or guest in many tenants; specifying this makes sure you land in the right one. Leave blank to use the account''s home tenant.'
            Type     = 'String'
            Required = $false
            Pattern  = '^[0-9a-fA-F-]{36}$'
            Example  = '00000000-0000-0000-0000-000000000000'
        }
        @{
            Name     = 'SubscriptionId'
            Label    = 'Subscription'
            Type     = 'Choice'
            Required = $true
            Source   = @{ Cmdlet = 'Get-AzSubscription'; Display = 'Name'; Value = 'Id'; Auth = 'Azure' }
            Help     = 'Name or ID both work with Set-AzContext. The ID is unambiguous.'
        }
    )
    Steps = @(
        @{
            Title      = 'Sign in'
            What       = 'Interactive sign-in. Skipped by Az if a cached token for this tenant is still valid.'
            Why        = 'Nothing else works without a token. Passing the tenant avoids landing in a guest tenant by accident.'
            Cmdlet     = 'Connect-AzAccount'
            Parameters = @{ Tenant = '{{TenantId}}' }
            WhatIf     = $false
        }
        @{
            Title  = 'See what you can reach'
            What   = 'List every enabled subscription the account can see.'
            Why    = 'The one you want may not be the default. Look before you set.'
            Raw    = @('Get-AzSubscription | Where-Object State -eq ''Enabled'' | Format-Table Name, Id, TenantId')
        }
        @{
            Title      = 'Select the subscription'
            What       = 'Point the session at one subscription. Every later cmdlet uses it unless told otherwise.'
            Why        = 'Running the right script against the wrong subscription is the classic Azure mistake. Make the target explicit.'
            Cmdlet     = 'Set-AzContext'
            Parameters = @{ Subscription = '{{SubscriptionId}}' }
            WhatIf     = $false
        }
    )
    Verify = @('Get-AzContext | Format-List Account, Tenant, Subscription')
    Docs   = @(
        'https://learn.microsoft.com/powershell/module/az.accounts/connect-azaccount'
        'https://learn.microsoft.com/powershell/module/az.accounts/set-azcontext'
    )
    Status = 'Untested'
}
