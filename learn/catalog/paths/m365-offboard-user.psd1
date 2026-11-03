@{
    Id      = 'path.m365.offboard-user'
    Title   = 'Offboard a user: block, forward, convert mailbox, remove licence'
    Summary = 'Block sign-in and revoke sessions, forward mail to the manager, convert the mailbox to shared, then remove the licence. Graph for the account, Exchange for the mailbox.'
    Tasks   = @('m365.users.block-sign-in', 'm365.exchange.set-forwarding', 'm365.exchange.convert-to-shared', 'm365.licenses.remove-license')
    Share   = @{ Mailbox = 'UserId' }
}
