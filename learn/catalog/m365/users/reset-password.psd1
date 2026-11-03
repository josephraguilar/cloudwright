@{
    Id      = 'm365.users.reset-password'
    Title   = 'Reset a user''s password'
    Summary = 'Sets a new password and forces a change at next sign-in. The new password is typed when the script runs.'
    Learn   = @(
        'Resetting the password does not end existing sessions. Pair it with Revoke-MgUserSignInSession (next task) when the account is compromised.'
        'Admins cannot reset passwords of users holding a higher role than their own. Global Admin passwords need another Global Admin.'
        'Synced users: reset in AD unless password writeback is enabled.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Users'); Scopes = @('User-PasswordProfile.ReadWrite.All'); Roles = @('Password Administrator (non-admins), User Administrator, or higher') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'UserId'; Label = 'User'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
        @{ Name = 'Password'; Label = 'New temporary password'; Help = 'The initial password. Not entered here: the generated script prompts for it when run, and the user must change it at first sign-in, so it only has to survive until then. Do not email it with the username.'; Type = 'Secret'; SecretKind = 'PlainText' }
    )
    Steps = @(
        @{
            Title      = 'Set the password profile'
            What       = 'PATCH the passwordProfile with the new password and the force-change flag.'
            Why        = 'The user picks their real password at next sign-in; yours is temporary.'
            Cmdlet     = 'Update-MgUser'
            Parameters = @{ UserId = '{{UserId}}'; PasswordProfile = '@{ Password = {{Password}}; ForceChangePasswordNextSignIn = $true }' }
            ParameterOrder = @('UserId', 'PasswordProfile')
        }
    )
    Verify = @('Get-MgUser -UserId {{UserId}} -Property DisplayName, LastPasswordChangeDateTime | Format-List DisplayName, LastPasswordChangeDateTime')
    Docs   = @('https://learn.microsoft.com/powershell/module/microsoft.graph.users/update-mguser')
    Status = 'Untested'
}
