@{
    Id      = 'm365.exchange.connect'
    Title   = 'Connect to Exchange Online'
    Summary = 'Signs in to Exchange Online PowerShell. Mailboxes, distribution lists, and mail flow live here, not in Graph.'
    Learn   = @(
        'The ExchangeOnlineManagement module v3 uses REST; no WinRM basic auth needed. Get-EXO* cmdlets are the fast, paged versions of Get-Mailbox etc.'
        'Your Exchange admin role (Exchange Administrator, Recipient Administrator, or a custom RBAC role) decides what works. There are no scopes to request.'
        'Disconnect-ExchangeOnline when done; sessions count against a per-user limit.'
    )
    Requires = @{ Auth = 'None'; Modules = @('ExchangeOnlineManagement'); Roles = @('Exchange Administrator or Recipient Administrator') }
    Fields = @(
        @{ Name = 'Upn'; Label = 'Your admin UPN (pre-fills the sign-in)'; Help = 'Your admin sign-in name. Pre-fills the sign-in prompt; optional.'; Type = 'String'; Required = $false; Example = 'admin@contoso.com' }
    )
    Steps = @(
        @{
            Title      = 'Connect'
            What       = 'Interactive sign-in to Exchange Online.'
            Why        = 'All Exchange cmdlets need this session.'
            Cmdlet     = 'Connect-ExchangeOnline'
            Parameters = @{ UserPrincipalName = '{{Upn}}'; ShowBanner = '$false' }
            ParameterOrder = @('UserPrincipalName', 'ShowBanner')
            Fixed          = @('ShowBanner')
            WhatIf     = $false
        }
    )
    Verify = @('Get-ConnectionInformation | Select-Object UserPrincipalName, TenantId, State')
    Docs   = @('https://learn.microsoft.com/powershell/exchange/connect-to-exchange-online-powershell')
    Status = 'Untested'
}
