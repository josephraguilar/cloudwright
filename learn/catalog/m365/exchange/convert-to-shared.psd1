@{
    Id      = 'm365.exchange.convert-to-shared'
    Title   = 'Convert a user mailbox to shared'
    Summary = 'Turns a leaver''s mailbox into a shared mailbox so the licence can be removed while the mail stays accessible to whoever is granted access.'
    Learn   = @(
        'Convert first, remove the licence second. A shared mailbox under 50 GB with no archive and no litigation hold needs no licence.'
        'Block sign-in before this (Graph task). The converted mailbox keeps the disabled account behind it.'
        'Over 50 GB, or with In-Place Archive or litigation hold, it still needs an Exchange Online Plan 2 licence.'
    )
    Requires = @{ Auth = 'ExchangeOnline'; Modules = @('ExchangeOnlineManagement'); Roles = @('Recipient Administrator') }
    Prerequisites = @('m365.users.block-sign-in')
    Fields = @(
        @{ Name = 'Mailbox'; Label = 'Mailbox'; Help = 'The mailbox, by primary email address. In Exchange Online every mailbox is also a user object; shared mailboxes have a disabled user behind them. The list comes from Get-EXOMailbox when connected to Exchange Online.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-EXOMailbox'; Parameters = @{ ResultSize = 'Unlimited' }; Display = 'PrimarySmtpAddress'; Value = 'PrimarySmtpAddress'; Auth = 'ExchangeOnline' } }
    )
    Steps = @(
        @{
            Title      = 'Convert'
            What       = 'Set-Mailbox -Type Shared.'
            Why        = 'Changes the RecipientTypeDetails; data and permissions are untouched.'
            Cmdlet     = 'Set-Mailbox'
            Parameters = @{ Identity = '{{Mailbox}}'; Type = '''Shared''' }
            ParameterOrder = @('Identity', 'Type')
            Fixed          = @('Type')
        }
    )
    Verify   = @('Get-EXOMailbox -Identity {{Mailbox}} | Select-Object PrimarySmtpAddress, RecipientTypeDetails, @{ n = ''SizeOk''; e = { ''check Get-EXOMailboxStatistics TotalItemSize < 50 GB'' } }')
    Rollback = @('Set-Mailbox -Identity {{Mailbox}} -Type Regular    # Needs a licence again within 30 days.')
    Docs     = @('https://learn.microsoft.com/microsoft-365/admin/email/convert-user-mailbox-to-shared-mailbox')
    Status   = 'Untested'
}
