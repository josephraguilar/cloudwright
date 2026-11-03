@{
    Id      = 'm365.licenses.assign-license'
    Title   = 'Assign a licence to a user'
    Summary = 'Adds one SKU to the user. Requires a usage location on the user and a free seat on the SKU.'
    Learn   = @(
        'Set-MgUserLicense always takes both AddLicenses and RemoveLicenses; pass an empty array for the one you are not using.'
        'Group-based licensing (assign the licence to a group, add users to the group) scales better than per-user. This task is the per-user form.'
        'Disabled service plans go in the same AddLicenses entry as DisabledPlans = @(<plan ids>).'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Users.Actions'); Scopes = @('User.ReadWrite.All', 'Organization.Read.All'); Roles = @('License Administrator or User Administrator') }
    Prerequisites = @('m365.users.new-user', 'm365.licenses.list-skus')
    Fields = @(
        @{ Name = 'UserId'; Label = 'User'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
        @{ Name = 'SkuId'; Label = 'Licence SKU'; Help = 'A licence SKU is one product subscription. The list shows SkuPartNumber, Microsofts internal name (SPE_E3 = Microsoft 365 E3, SPE_E5 = E5, O365_BUSINESS_PREMIUM = Microsoft 365 Business Standard, SPB = Business Premium, EXCHANGESTANDARD = Exchange Online Plan 1), and writes the SkuId GUID. Microsoft publishes a CSV mapping names to products.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgSubscribedSku'; Display = 'SkuPartNumber'; Value = 'SkuId'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title      = 'Add the licence'
            What       = 'POST /users/{id}/assignLicense with one SKU to add and nothing to remove.'
            Why        = 'Mailbox and OneDrive are provisioned minutes after this lands.'
            Cmdlet     = 'Set-MgUserLicense'
            Parameters = @{ UserId = '{{UserId}}'; AddLicenses = '@(@{ SkuId = {{SkuId}} })'; RemoveLicenses = '@()' }
            ParameterOrder = @('UserId', 'AddLicenses', 'RemoveLicenses')
            Fixed          = @('RemoveLicenses')
        }
    )
    Verify   = @('Get-MgUserLicenseDetail -UserId {{UserId}} | Format-Table SkuPartNumber, SkuId')
    Rollback = @('Set-MgUserLicense -UserId {{UserId}} -AddLicenses @() -RemoveLicenses @({{SkuId}})')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.users.actions/set-mguserlicense')
    Status   = 'Untested'
}
