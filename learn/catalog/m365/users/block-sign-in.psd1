@{
    Id      = 'm365.users.block-sign-in'
    Title   = 'Block sign-in and revoke sessions'
    Summary = 'Disables the account and invalidates every refresh token, so existing Outlook, Teams, and mobile sessions stop within the hour. First step of any offboarding or compromise response.'
    Learn   = @(
        'AccountEnabled false blocks new sign-ins immediately. Revoking sessions kills the refresh tokens; access tokens already issued live up to an hour.'
        'The mailbox, OneDrive, and licences are untouched. Keep the licence until data is handed over, then remove it.'
        'Reversible: set AccountEnabled back to true.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Users'); Scopes = @('User.ReadWrite.All', 'User.RevokeSessions.All'); Roles = @('User Administrator') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'UserId'; Label = 'User'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title      = 'Disable the account'
            What       = 'Sets accountEnabled to false.'
            Why        = 'Stops new sign-ins.'
            Cmdlet     = 'Update-MgUser'
            Parameters = @{ UserId = '{{UserId}}'; AccountEnabled = '$false' }
            ParameterOrder = @('UserId', 'AccountEnabled')
            Fixed          = @('AccountEnabled')
        }
        @{
            Title      = 'Revoke sign-in sessions'
            What       = 'Invalidates all refresh tokens issued to the user.'
            Why        = 'Stops sessions that are already open.'
            Cmdlet     = 'Revoke-MgUserSignInSession'
            Parameters = @{ UserId = '{{UserId}}' }
        }
    )
    Verify   = @('Get-MgUser -UserId {{UserId}} -Property DisplayName, AccountEnabled, SignInSessionsValidFromDateTime | Format-List DisplayName, AccountEnabled, SignInSessionsValidFromDateTime')
    Rollback = @('Update-MgUser -UserId {{UserId}} -AccountEnabled:$true')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.users/revoke-mgusersigninsession')
    Status   = 'Untested'
}
