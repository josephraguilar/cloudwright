@{
    Id      = 'm365.users.set-manager'
    Title   = 'Set a user''s manager'
    Summary = 'Points the manager reference at another user. Drives org charts, approval flows, and the "manager" field in Outlook.'
    Learn   = @(
        'Manager is a navigation property, so it is set by reference with an @odata.id URL, not a plain Id.'
        'Remove it with Remove-MgUserManagerByRef.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Users'); Scopes = @('User.ReadWrite.All'); Roles = @('User Administrator') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'UserId'; Label = 'User'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
        @{ Name = 'ManagerId'; Label = 'Manager'; Help = 'The manager, by sign-in name. Drives org charts and approval flows.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title = 'Set the manager reference'
            What  = 'PUT /users/{id}/manager/$ref with the manager''s object URL.'
            Why   = 'Reference properties take a URL, so the manager is looked up to get the Id.'
            Raw   = @('Set-MgUserManagerByRef -UserId {{UserId}} -BodyParameter @{ ''@odata.id'' = "https://graph.microsoft.com/v1.0/users/$((Get-MgUser -UserId {{ManagerId}}).Id)" }')
        }
    )
    Verify   = @('Get-MgUserManager -UserId {{UserId}} | Select-Object Id, @{ n = ''Manager''; e = { $_.AdditionalProperties.userPrincipalName } }')
    Rollback = @('Remove-MgUserManagerByRef -UserId {{UserId}}')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.users/set-mgusermanagerbyref')
    Status   = 'Untested'
}
