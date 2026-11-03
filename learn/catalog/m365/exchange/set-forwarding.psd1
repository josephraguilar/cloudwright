@{
    Id      = 'm365.exchange.set-forwarding'
    Title   = 'Forward a mailbox to another address'
    Summary = 'Sets admin-level forwarding on a mailbox, optionally keeping a copy. Used during leave cover and offboarding.'
    Learn   = @(
        'ForwardingSmtpAddress works for any address. ForwardingAddress (no Smtp) needs a mail contact or recipient in the tenant. External forwarding may be blocked by the outbound spam policy; check if mail does not arrive.'
        'Users can set their own forwarding in Outlook rules; this admin setting takes precedence and is visible in audit logs.'
    )
    Requires = @{ Auth = 'ExchangeOnline'; Modules = @('ExchangeOnlineManagement'); Roles = @('Recipient Administrator') }
    Prerequisites = @('m365.exchange.connect')
    Fields = @(
        @{ Name = 'Mailbox'; Label = 'Mailbox'; Help = 'The mailbox, by primary email address. In Exchange Online every mailbox is also a user object; shared mailboxes have a disabled user behind them. The list comes from Get-EXOMailbox when connected to Exchange Online.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-EXOMailbox'; Parameters = @{ ResultSize = 'Unlimited' }; Display = 'PrimarySmtpAddress'; Value = 'PrimarySmtpAddress'; Auth = 'ExchangeOnline' } }
        @{ Name = 'ForwardTo'; Label = 'Forward to (email address)'; Help = 'Destination email address. Internal addresses always work. External addresses are often blocked by the tenant''s outbound anti-spam policy (AutoForwardingMode), so mail silently stops; check that policy if forwards do not arrive.'; Type = 'String'; Required = $true; Pattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'; Example = 'manager@contoso.com' }
        @{ Name = 'KeepCopy'; Label = 'Keep a copy in the original mailbox'; Help = 'DeliverToMailboxAndForward: when on, each message is delivered to the original mailbox and a copy is forwarded. When off, messages only go to the forwarding address and the original mailbox stays empty (common during offboarding so nothing is missed in the old box).'; Type = 'TrueFalse'; Required = $false; Default = $true }
    )
    Steps = @(
        @{
            Title      = 'Set forwarding'
            What       = 'Sets ForwardingSmtpAddress and DeliverToMailboxAndForward.'
            Why        = 'Mail arrives at the new address from the next message on.'
            Cmdlet     = 'Set-Mailbox'
            Parameters = @{ Identity = '{{Mailbox}}'; ForwardingSmtpAddress = '{{ForwardTo}}'; DeliverToMailboxAndForward = '{{KeepCopy}}' }
            ParameterOrder = @('Identity', 'ForwardingSmtpAddress', 'DeliverToMailboxAndForward')
            BoolParameters = @('DeliverToMailboxAndForward')
        }
    )
    Verify   = @('Get-EXOMailbox -Identity {{Mailbox}} -Properties ForwardingSmtpAddress, DeliverToMailboxAndForward | Select-Object PrimarySmtpAddress, ForwardingSmtpAddress, DeliverToMailboxAndForward')
    Rollback = @('Set-Mailbox -Identity {{Mailbox}} -ForwardingSmtpAddress $null -DeliverToMailboxAndForward $false')
    Docs     = @('https://learn.microsoft.com/powershell/module/exchange/set-mailbox')
    Status   = 'Untested'
}
