@{
    Id      = 'm365.licenses.list-skus'
    Title   = 'List licence SKUs and how many are in use'
    Summary = 'Every subscription in the tenant with purchased and consumed counts. The SkuId is what licence assignment needs.'
    Learn   = @(
        'SkuPartNumber is the internal name (SPE_E3 = Microsoft 365 E3, O365_BUSINESS_PREMIUM = Microsoft 365 Business Standard). The friendly names are in Microsoft''s product-names CSV.'
        'Consumed can exceed Enabled briefly after a renewal lapses; those users are in a grace state.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Identity.DirectoryManagement'); Scopes = @('Organization.Read.All'); Roles = @('Any admin role or Directory Readers') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @()
    Steps = @(
        @{
            Title = 'List SKUs'
            What  = 'Reads subscribedSkus and shows name, Id, purchased, consumed.'
            Why   = 'Copy the SkuId into the assign-licence task if the pick list is unavailable.'
            Raw   = @('Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId, ConsumedUnits, @{ n = ''Enabled''; e = { $_.PrepaidUnits.Enabled } } | Sort-Object SkuPartNumber | Format-Table -AutoSize')
        }
    )
    Docs   = @('https://learn.microsoft.com/powershell/module/microsoft.graph.identity.directorymanagement/get-mgsubscribedsku', 'https://learn.microsoft.com/entra/identity/users/licensing-service-plan-reference')
    Status = 'Untested'
}
