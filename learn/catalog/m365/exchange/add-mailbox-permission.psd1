@{
    Id      = 'm365.exchange.add-mailbox-permission'
    Title   = 'Grant a user access to another mailbox'
    Summary = 'Full Access, Send As, or Send on Behalf on any mailbox (shared or a person''s).'
    Learn   = @(
        'Full Access and Send As are separate permissions set by different cmdlets. Send on Behalf is a mailbox property (GrantSendOnBehalfTo).'
        'Permissions on a user mailbox are logged and visible to the owner in some cases. Have a ticket.'
    )
    Requires = @{ Auth = 'ExchangeOnline'; Modules = @('ExchangeOnlineManagement'); Roles = @('Recipient Administrator') }
    Prerequisites = @('m365.exchange.connect')
    Fields = @(
        @{ Name = 'Mailbox'; Label = 'Mailbox'; Help = 'The mailbox, by primary email address. In Exchange Online every mailbox is also a user object; shared mailboxes have a disabled user behind them. The list comes from Get-EXOMailbox when connected to Exchange Online.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-EXOMailbox'; Parameters = @{ ResultSize = 'Unlimited' }; Display = 'PrimarySmtpAddress'; Value = 'PrimarySmtpAddress'; Auth = 'ExchangeOnline' } }
        @{ Name = 'User'; Label = 'User to grant'; Help = 'The user receiving the permission, by sign-in name.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-EXOMailbox'; Parameters = @{ ResultSize = 'Unlimited' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'ExchangeOnline' } }
        @{ Name = 'FullAccess'; Label = 'Full Access (open the mailbox)'; Help = 'Full Access: the user can open the mailbox and read, move, and delete everything in it, but cannot send from it without Send As or Send on Behalf. This is the permission Outlook uses to show the mailbox.'; Type = 'Bool'; Required = $false; Default = $true }
        @{ Name = 'AutoMapping'; Label = 'Automap in Outlook (Full Access only)'; Help = 'Exchange automapping: when on, Outlook on the desktop discovers mailboxes the user has Full Access to and opens them automatically (takes up to an hour, cannot be removed by the user). When off, the user adds the mailbox manually in Outlook. Turn it off for people with many mailboxes or for occasional-use mailboxes, since each mapped mailbox syncs and slows Outlook.'; Type = 'TrueFalse'; Required = $false; Default = $true }
        @{ Name = 'SendAs'; Label = 'Send As'; Help = 'Send As: mail sent by the user shows the shared mailbox as the sender with no trace of who sent it. Compare Send on Behalf, which shows "Jane on behalf of Support". Grant one or the other, not both.'; Type = 'Bool'; Required = $false; Default = $false }
        @{ Name = 'SendOnBehalf'; Label = 'Send on Behalf'; Help = 'Send on Behalf: recipients see "Jane Doe on behalf of Support". Compare Send As, where the message looks like it came from Support directly. Grant one or the other.'; Type = 'Bool'; Required = $false; Default = $false }
    )
    Steps = @(
        @{
            Title      = 'Full Access'
            When       = 'FullAccess'
            What       = 'Adds FullAccess with automapping.'
            Why        = 'Outlook opens the mailbox automatically.'
            Cmdlet     = 'Add-MailboxPermission'
            Parameters = @{ Identity = '{{Mailbox}}'; User = '{{User}}'; AccessRights = '''FullAccess'''; AutoMapping = '{{AutoMapping}}' }
            ParameterOrder = @('Identity', 'User', 'AccessRights', 'AutoMapping')
            BoolParameters = @('AutoMapping')
            Fixed          = @('AccessRights')
        }
        @{
            Title      = 'Send As'
            When       = 'SendAs'
            What       = 'Adds SendAs on the recipient.'
            Why        = 'Mail appears to come from the mailbox itself.'
            Cmdlet     = 'Add-RecipientPermission'
            Parameters = @{ Identity = '{{Mailbox}}'; Trustee = '{{User}}'; AccessRights = '''SendAs'''; Confirm = '$false' }
            ParameterOrder = @('Identity', 'Trustee', 'AccessRights', 'Confirm')
            Fixed          = @('AccessRights', 'Confirm')
        }
        @{
            Title      = 'Send on Behalf'
            When       = 'SendOnBehalf'
            What       = 'Appends the user to GrantSendOnBehalfTo.'
            Why        = 'Mail shows "user on behalf of mailbox".'
            Cmdlet     = 'Set-Mailbox'
            Parameters = @{ Identity = '{{Mailbox}}'; GrantSendOnBehalfTo = '@{ Add = {{User}} }' }
            ParameterOrder = @('Identity', 'GrantSendOnBehalfTo')
        }
    )
    Verify   = @('Get-EXOMailboxPermission -Identity {{Mailbox}} -User {{User}} | Format-Table User, AccessRights', 'Get-EXORecipientPermission -Identity {{Mailbox}} -Trustee {{User}} | Format-Table Trustee, AccessRights')
    Rollback = @('Remove-MailboxPermission -Identity {{Mailbox}} -User {{User}} -AccessRights FullAccess -Confirm:$false', 'Remove-RecipientPermission -Identity {{Mailbox}} -Trustee {{User}} -AccessRights SendAs -Confirm:$false')
    Docs     = @('https://learn.microsoft.com/powershell/module/exchange/add-mailboxpermission', 'https://learn.microsoft.com/powershell/module/exchange/add-recipientpermission')
    Status   = 'Untested'
}
