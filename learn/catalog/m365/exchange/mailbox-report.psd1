@{
    Id      = 'm365.exchange.mailbox-report'
    Title   = 'Largest mailboxes report'
    Summary = 'Mailbox size and last logon for every mailbox, biggest first. The quick answer to "who is near quota" and "which leavers still have a mailbox".'
    Learn   = @(
        'Get-EXOMailboxStatistics is per mailbox, so this pipes every mailbox through it. Large tenants: minutes.'
        'TotalItemSize is a string with bytes in parentheses; sorting works on the deserialised value in EXO v3.'
    )
    Requires = @{ Auth = 'ExchangeOnline'; Modules = @('ExchangeOnlineManagement'); Roles = @('View-Only Recipients') }
    Prerequisites = @('m365.exchange.connect')
    Fields = @(
        @{ Name = 'Top'; Label = 'How many to show'; Help = 'How many rows to show.'; Type = 'Int'; Required = $true; Default = '25' }
    )
    Steps = @(
        @{
            Title = 'Report'
            What  = 'Statistics for all mailboxes, sorted by size.'
            Why   = 'Capacity planning and offboarding hygiene.'
            Fixed = @('ResultSize')
            Raw   = @('Get-EXOMailbox -ResultSize Unlimited | Get-EXOMailboxStatistics | Sort-Object TotalItemSize -Descending | Select-Object -First {{Top}} DisplayName, TotalItemSize, ItemCount, LastLogonTime | Format-Table -AutoSize')
        }
    )
    Docs   = @('https://learn.microsoft.com/powershell/module/exchange/get-exomailboxstatistics')
    Status = 'Untested'
}
