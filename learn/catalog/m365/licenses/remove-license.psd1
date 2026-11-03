@{
    Id      = 'm365.licenses.remove-license'
    Title   = 'Remove a licence from a user'
    Summary = 'Takes one SKU off the user and frees the seat. Mailbox and OneDrive enter a 30-day grace before deletion.'
    Learn   = @(
        'Removing an Exchange licence from a user whose mailbox you want to keep: convert the mailbox to shared first (Exchange task), then remove the licence.'
        'Licences inherited from a group cannot be removed here; remove the user from the group.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Users.Actions'); Scopes = @('User.ReadWrite.All'); Roles = @('License Administrator or User Administrator') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'UserId'; Label = 'User'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
        @{ Name = 'SkuId'; Label = 'Licence SKU to remove'; Help = 'A licence SKU is one product subscription. The list shows SkuPartNumber, Microsofts internal name (SPE_E3 = Microsoft 365 E3, SPE_E5 = E5, O365_BUSINESS_PREMIUM = Microsoft 365 Business Standard, SPB = Business Premium, EXCHANGESTANDARD = Exchange Online Plan 1), and writes the SkuId GUID. Microsoft publishes a CSV mapping names to products.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgSubscribedSku'; Display = 'SkuPartNumber'; Value = 'SkuId'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title      = 'Remove the licence'
            What       = 'assignLicense with nothing to add and one SKU to remove.'
            Why        = 'Frees the seat immediately.'
            Cmdlet     = 'Set-MgUserLicense'
            Parameters = @{ UserId = '{{UserId}}'; AddLicenses = '@()'; RemoveLicenses = '@({{SkuId}})' }
            ParameterOrder = @('UserId', 'AddLicenses', 'RemoveLicenses')
            Fixed          = @('AddLicenses')
        }
    )
    Verify   = @('Get-MgUserLicenseDetail -UserId {{UserId}} | Format-Table SkuPartNumber, SkuId')
    Rollback = @('Set-MgUserLicense -UserId {{UserId}} -AddLicenses @(@{ SkuId = {{SkuId}} }) -RemoveLicenses @()')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.users.actions/set-mguserlicense')
    Status   = 'Untested'
}
