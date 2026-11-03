@{
    Id      = 'm365.users.new-user'
    Title   = 'Create a user'
    Summary = 'Creates a cloud user with a usage location (required before any licence) and an initial password that must be changed at first sign-in.'
    Learn   = @(
        'UsageLocation is a two-letter country code and is mandatory for licence assignment. Forgetting it is the most common reason Set-MgUserLicense fails.'
        'The password is typed when the script runs. The user is forced to change it on first sign-in, so it only has to survive until then.'
        'If the tenant syncs from on-prem AD, create the user in AD instead; cloud-created users cannot be matched later without pain.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Users'); Scopes = @('User.ReadWrite.All'); Roles = @('User Administrator') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'DisplayName'; Label = 'Display name'; Help = 'The human-readable name shown in portals and address lists.'; Type = 'String'; Required = $true; Example = 'Jane Doe' }
        @{ Name = 'GivenName'; Label = 'First name'; Help = 'First name.'; Type = 'String'; Required = $false; Example = 'Jane' }
        @{ Name = 'Surname'; Label = 'Last name'; Help = 'Last name.'; Type = 'String'; Required = $false; Example = 'Doe' }
        @{ Name = 'UserPrincipalName'; Label = 'Sign-in name (UPN)'; Help = 'The sign-in name, user@domain. The domain must be verified in the tenant.'; Type = 'String'; Required = $true; Pattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'; Example = 'jane.doe@contoso.com' }
        @{ Name = 'MailNickname'; Label = 'Mail nickname (alias, no spaces)'; Help = 'The alias: the part of the address before the @, and the value Exchange uses internally to name the object. Required by Graph even for security groups that will never have a mailbox. Letters, digits, dots, hyphens, underscores; no spaces; unique in the tenant.'; Type = 'String'; Required = $true; Pattern = '^[A-Za-z0-9._-]{1,64}$'; Example = 'jane.doe' }
        @{ Name = 'UsageLocation'; Label = 'Usage location (country, needed for licences)'; Help = 'Two-letter ISO country code recorded on the user. Microsoft uses it to decide which services may legally be enabled (some features are not available in all countries), so licence assignment fails without it. It is not the users office location field.'; Type = 'Choice'; Required = $true; Default = 'US'; Options = @('US', 'CA', 'GB', 'IE', 'AU', 'NZ', 'DE', 'FR', 'NL', 'IN') }
        @{ Name = 'JobTitle'; Label = 'Job title'; Help = 'The job title shown on the profile card and in the address book.'; Type = 'String'; Required = $false }
        @{ Name = 'Department'; Label = 'Department'; Help = 'The department shown on the profile and usable in dynamic group rules.'; Type = 'String'; Required = $false }
        @{ Name = 'AccountEnabled'; Label = 'Account enabled at creation'; Help = 'Whether the account can sign in at all. Off = sign-in blocked (the state used for offboarding and compromised accounts); the user, mailbox, and licences still exist. On is normal for a new hire; create disabled when the start date is in the future.'; Type = 'TrueFalse'; Required = $false; Default = $true }
        @{ Name = 'Password'; Label = 'Initial password'; Help = 'The initial password. Not entered here: the generated script prompts for it when run, and the user must change it at first sign-in, so it only has to survive until then. Do not email it with the username.'; Type = 'Secret'; SecretKind = 'PlainText' }
    )
    Steps = @(
        @{
            Title      = 'Create the user'
            What       = 'POST /users with accountEnabled true and a password profile that forces a change at next sign-in.'
            Why        = 'Everything else (licence, groups, manager) references the Id this returns.'
            Cmdlet     = 'New-MgUser'
            Parameters = @{ DisplayName = '{{DisplayName}}'; GivenName = '{{GivenName}}'; Surname = '{{Surname}}'; UserPrincipalName = '{{UserPrincipalName}}'; MailNickname = '{{MailNickname}}'; UsageLocation = '{{UsageLocation}}'; JobTitle = '{{JobTitle}}'; Department = '{{Department}}'; AccountEnabled = '{{AccountEnabled}}'
                PasswordProfile = '@{ Password = {{Password}}; ForceChangePasswordNextSignIn = $true }' }
            ParameterOrder = @('DisplayName', 'GivenName', 'Surname', 'UserPrincipalName', 'MailNickname', 'UsageLocation', 'JobTitle', 'Department', 'AccountEnabled', 'PasswordProfile')
            Output     = 'user'
        }
    )
    Verify   = @('Get-MgUser -UserId {{UserPrincipalName}} -Property Id, DisplayName, UserPrincipalName, UsageLocation, AccountEnabled, CreatedDateTime | Format-List Id, DisplayName, UserPrincipalName, UsageLocation, AccountEnabled, CreatedDateTime')
    Rollback = @('Remove-MgUser -UserId {{UserPrincipalName}}    # Soft-deleted 30 days; restore from Entra admin center > Users > Deleted users.')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.users/new-mguser')
    Status   = 'Untested'
}
