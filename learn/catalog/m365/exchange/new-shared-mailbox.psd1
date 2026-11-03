@{
    Id      = 'm365.exchange.new-shared-mailbox'
    Title   = 'Create a shared mailbox and grant access'
    Summary = 'A licence-free mailbox (under 50 GB) that several people open. Full Access makes it appear in Outlook; Send As lets them send from its address.'
    Learn   = @(
        'Shared mailboxes have a disabled user account behind them. Nobody signs in to it directly.'
        'AutoMapping true makes Outlook open it automatically for Full Access users within an hour. Set it false for mailboxes people only open occasionally.'
        'Send As = mail appears from the shared address. Send on Behalf = "user on behalf of mailbox". Pick one per user, not both.'
    )
    Requires = @{ Auth = 'ExchangeOnline'; Modules = @('ExchangeOnlineManagement'); Roles = @('Recipient Administrator') }
    Prerequisites = @('m365.exchange.connect')
    Fields = @(
        @{ Name = 'Name'; Label = 'Mailbox name'; Help = 'The resource name. Pick something that says what it is and which environment it belongs to.'; Type = 'String'; Required = $true; Example = 'Support' }
        @{ Name = 'Alias'; Label = 'Alias (no spaces)'; Help = 'The short mail alias, no spaces. Becomes the local part of the address unless one is given.'; Type = 'String'; Required = $true; Pattern = '^[A-Za-z0-9._-]{1,64}$'; Example = 'support' }
        @{ Name = 'PrimarySmtpAddress'; Label = 'Email address'; Help = 'The primary email address. The domain must be verified in the tenant.'; Type = 'String'; Required = $true; Pattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'; Example = 'support@contoso.com' }
        @{ Name = 'FullAccessUser'; Label = 'User to grant Full Access (blank to skip)'; Help = 'User who should be able to open the mailbox. Leave blank to grant access later.'; Type = 'Choice'; Required = $false
           Source = @{ Cmdlet = 'Get-EXOMailbox'; Parameters = @{ ResultSize = 'Unlimited' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'ExchangeOnline' } }
        @{ Name = 'AutoMapping'; Label = 'Automap in Outlook for that user'; Help = 'Exchange automapping: when on, Outlook on the desktop discovers mailboxes the user has Full Access to and opens them automatically (takes up to an hour, cannot be removed by the user). When off, the user adds the mailbox manually in Outlook. Turn it off for people with many mailboxes or for occasional-use mailboxes, since each mapped mailbox syncs and slows Outlook.'; Type = 'TrueFalse'; Required = $false; Default = $true }
        @{ Name = 'SendAs'; Label = 'Also grant Send As to that user'; Help = 'Send As: mail sent by the user shows the shared mailbox as the sender with no trace of who sent it. Compare Send on Behalf, which shows "Jane on behalf of Support". Grant one or the other, not both.'; Type = 'Bool'; Required = $false; Default = $true }
    )
    Steps = @(
        @{
            Title      = 'Create the shared mailbox'
            What       = 'New-Mailbox -Shared creates the mailbox and its disabled account.'
            Why        = 'Takes a minute to appear in the address list.'
            Cmdlet     = 'New-Mailbox'
            Parameters = @{ Shared = '$true'; Name = '{{Name}}'; DisplayName = '{{Name}}'; Alias = '{{Alias}}'; PrimarySmtpAddress = '{{PrimarySmtpAddress}}' }
            ParameterOrder = @('Shared', 'Name', 'DisplayName', 'Alias', 'PrimarySmtpAddress')
            Fixed          = @('Shared')
        }
        @{
            Title      = 'Grant Full Access'
            When       = 'FullAccessUser'
            What       = 'Mailbox permission with automapping.'
            Why        = 'Lets the user open the mailbox in Outlook and OWA.'
            Cmdlet     = 'Add-MailboxPermission'
            Parameters = @{ Identity = '{{PrimarySmtpAddress}}'; User = '{{FullAccessUser}}'; AccessRights = '''FullAccess'''; AutoMapping = '{{AutoMapping}}' }
            ParameterOrder = @('Identity', 'User', 'AccessRights', 'AutoMapping')
            BoolParameters = @('AutoMapping')
            Fixed          = @('AccessRights')
        }
        @{
            Title      = 'Grant Send As'
            When       = 'SendAs'
            What       = 'Recipient permission so mail can be sent from the shared address.'
            Why        = 'Full Access alone does not allow sending as the mailbox.'
            Cmdlet     = 'Add-RecipientPermission'
            Parameters = @{ Identity = '{{PrimarySmtpAddress}}'; Trustee = '{{FullAccessUser}}'; AccessRights = '''SendAs'''; Confirm = '$false' }
            ParameterOrder = @('Identity', 'Trustee', 'AccessRights', 'Confirm')
            Fixed          = @('AccessRights', 'Confirm')
        }
    )
    Verify   = @('Get-EXOMailbox -Identity {{PrimarySmtpAddress}} | Select-Object DisplayName, RecipientTypeDetails, PrimarySmtpAddress', 'Get-EXOMailboxPermission -Identity {{PrimarySmtpAddress}} | Where-Object User -ne ''NT AUTHORITY\SELF'' | Format-Table User, AccessRights')
    Rollback = @('Remove-Mailbox -Identity {{PrimarySmtpAddress}} -Confirm:$false    # Soft-deleted 30 days.')
    Docs     = @('https://learn.microsoft.com/powershell/module/exchange/new-mailbox', 'https://learn.microsoft.com/powershell/module/exchange/add-mailboxpermission')
    Status   = 'Untested'
}
