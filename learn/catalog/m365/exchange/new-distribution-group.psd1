@{
    Id      = 'm365.exchange.new-distribution-group'
    Title   = 'Create a distribution list'
    Summary = 'A classic mail distribution group with initial members. For a group that also needs files and a calendar, create a Microsoft 365 group instead.'
    Learn   = @(
        'Distribution groups are Exchange objects; Graph sees them read-only. Members are managed with Add/Remove-DistributionGroupMember.'
        'RequireSenderAuthenticationEnabled true (default) blocks external senders. Set it false for a group that receives mail from outside.'
    )
    Requires = @{ Auth = 'ExchangeOnline'; Modules = @('ExchangeOnlineManagement'); Roles = @('Recipient Administrator') }
    Prerequisites = @('m365.exchange.connect')
    Fields = @(
        @{ Name = 'Name'; Label = 'Group name'; Help = 'The resource name. Pick something that says what it is and which environment it belongs to.'; Type = 'String'; Required = $true; Example = 'All Sales' }
        @{ Name = 'Alias'; Label = 'Alias'; Help = 'The short mail alias, no spaces. Becomes the local part of the address unless one is given.'; Type = 'String'; Required = $true; Pattern = '^[A-Za-z0-9._-]{1,64}$'; Example = 'all-sales' }
        @{ Name = 'PrimarySmtpAddress'; Label = 'Email address'; Help = 'The primary email address. The domain must be verified in the tenant.'; Type = 'String'; Required = $true; Pattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'; Example = 'all-sales@contoso.com' }
        @{ Name = 'Members'; Label = 'Initial members'; Help = 'Initial members by sign-in name. A distribution list expands to its members at send time; it has no mailbox of its own and no shared files, unlike a Microsoft 365 group. Add or remove members later with Add/Remove-DistributionGroupMember.'; Type = 'MultiChoice'; Required = $false
           Source = @{ Cmdlet = 'Get-EXOMailbox'; Parameters = @{ ResultSize = 'Unlimited' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'ExchangeOnline' } }
        @{ Name = 'AllowExternal'; Label = 'Allow external senders'; Help = 'RequireSenderAuthenticationEnabled off: anyone on the internet can email the list, not just users in the tenant. Needed for a support@ or sales@ list that customers write to; leave off for internal lists, otherwise they become a spam funnel.'; Type = 'Bool'; Required = $false; Default = $false }
    )
    Steps = @(
        @{
            Title      = 'Create the group'
            What       = 'New-DistributionGroup with members.'
            Why        = 'One call creates the group and seeds membership.'
            Cmdlet     = 'New-DistributionGroup'
            Parameters = @{ Name = '{{Name}}'; Alias = '{{Alias}}'; PrimarySmtpAddress = '{{PrimarySmtpAddress}}'; Members = '{{Members}}' }
            ParameterOrder = @('Name', 'Alias', 'PrimarySmtpAddress', 'Members')
        }
        @{
            Title      = 'Allow external senders'
            When       = 'AllowExternal'
            What       = 'Turns off sender authentication requirement.'
            Why        = 'Only when the list must receive mail from outside the tenant.'
            Cmdlet     = 'Set-DistributionGroup'
            Parameters = @{ Identity = '{{PrimarySmtpAddress}}'; RequireSenderAuthenticationEnabled = '$false' }
            ParameterOrder = @('Identity', 'RequireSenderAuthenticationEnabled')
            BoolParameters = @('RequireSenderAuthenticationEnabled')
            Fixed          = @('RequireSenderAuthenticationEnabled')     # driven by the AllowExternal field via When
        }
    )
    Verify   = @('Get-DistributionGroupMember -Identity {{PrimarySmtpAddress}} | Format-Table DisplayName, PrimarySmtpAddress')
    Rollback = @('Remove-DistributionGroup -Identity {{PrimarySmtpAddress}} -Confirm:$false')
    Docs     = @('https://learn.microsoft.com/powershell/module/exchange/new-distributiongroup')
    Status   = 'Untested'
}
