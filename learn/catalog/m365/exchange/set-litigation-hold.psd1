@{
    Id      = 'm365.exchange.set-litigation-hold'
    Title   = 'Put a mailbox on litigation hold'
    Summary = 'Preserves everything in the mailbox, including items the user deletes, for a set number of days or indefinitely.'
    Learn   = @(
        'Needs Exchange Online Plan 2 (included in E3/E5) or the Exchange Online Archiving add-on.'
        'Hold takes up to an hour to apply. Items deleted before that are not protected.'
        'Duration in days from when each item was received, not from today. Leave it blank (unlimited) for legal matters with no end date.'
    )
    Requires = @{ Auth = 'ExchangeOnline'; Modules = @('ExchangeOnlineManagement'); Roles = @('Exchange Administrator, or Legal Hold role in Purview') }
    Prerequisites = @('m365.exchange.connect')
    Fields = @(
        @{ Name = 'Mailbox'; Label = 'Mailbox'; Help = 'The mailbox, by primary email address. In Exchange Online every mailbox is also a user object; shared mailboxes have a disabled user behind them. The list comes from Get-EXOMailbox when connected to Exchange Online.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-EXOMailbox'; Parameters = @{ ResultSize = 'Unlimited' }; Display = 'PrimarySmtpAddress'; Value = 'PrimarySmtpAddress'; Auth = 'ExchangeOnline' } }
        @{ Name = 'Days'; Label = 'Hold duration in days (blank = unlimited)'; Help = 'Litigation hold duration in days, counted from when each item was received (not from today), so a 2555-day (7-year) hold keeps every item for 7 years after it arrived. Blank means items are held indefinitely until the hold is removed. Held items the user deletes stay in the hidden Recoverable Items folder.'; Type = 'Int'; Required = $false; Example = '2555' }
    )
    Steps = @(
        @{
            Title      = 'Enable the hold'
            What       = 'Sets LitigationHoldEnabled and, if given, the duration.'
            Why        = 'Recoverable Items stops purging.'
            Cmdlet     = 'Set-Mailbox'
            Parameters = @{ Identity = '{{Mailbox}}'; LitigationHoldEnabled = '$true'; LitigationHoldDuration = '{{Days}}' }
            ParameterOrder = @('Identity', 'LitigationHoldEnabled', 'LitigationHoldDuration')
            BoolParameters = @('LitigationHoldEnabled')
            Fixed          = @('LitigationHoldEnabled')
        }
    )
    Verify   = @('Get-EXOMailbox -Identity {{Mailbox}} -Properties LitigationHoldEnabled, LitigationHoldDate, LitigationHoldDuration | Select-Object PrimarySmtpAddress, LitigationHoldEnabled, LitigationHoldDate, LitigationHoldDuration')
    Rollback = @('Set-Mailbox -Identity {{Mailbox}} -LitigationHoldEnabled $false')
    Docs     = @('https://learn.microsoft.com/purview/ediscovery-create-a-litigation-hold')
    Status   = 'Untested'
}
