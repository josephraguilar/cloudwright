@{
    Id      = 'azure.monitor.new-log-analytics'
    Title   = 'Create a Log Analytics workspace'
    Summary = 'Where diagnostics, AVD Insights, VM logs, and alerts get their data. One per environment is usual.'
    Learn   = @(
        'PerGB2018 is pay-per-GB ingested. The first 5 GB a month per workspace is free. Retention beyond 31 days costs extra per GB.'
        'AVD Insights needs the host pool and workspace diagnostic settings pointed here, plus the Azure Monitor agent on hosts.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.OperationalInsights'); Roles = @('Contributor on the resource group') }
    Prerequisites = @('azure.create.resource-group')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'WorkspaceName'; Label = 'Workspace name'; Help = 'An AVD workspace is the container that appears in the Windows App / Remote Desktop client. It lists the app groups registered to it; an app group belongs to at most one workspace. Metadata only, no compute, no cost.'; Type = 'String'; Required = $true; Example = 'log-avd-lab'; Pattern = '^[A-Za-z0-9][A-Za-z0-9-]{2,61}[A-Za-z0-9]$' }
        @{ Name = 'Sku'; Label = 'Pricing tier'; Help = 'Pricing model for ingested data. PerGB2018 = pay per GB ingested (first 5 GB per month free). CapacityReservation = commit to 100 GB/day or more for a discount; only worth it at that volume. Retention is priced separately.'; Type = 'Choice'; Required = $true; Default = 'PerGB2018'; Options = @(@{ Display = 'PerGB2018 (pay per GB)'; Value = 'PerGB2018' }, @{ Display = 'CapacityReservation (commitment tier)'; Value = 'CapacityReservation' }) }
        @{ Name = 'RetentionDays'; Label = 'Retention in days (30-730)'; Help = 'How long Log Analytics keeps data queryable. 30 days (31 for some tables) is included in the ingestion price; longer retention costs per GB per month. Archive tiers exist for keeping data cheaply without fast queries. Compliance needs usually decide this, not troubleshooting.'; Type = 'Int'; Required = $true; Default = '30' }
    )
    Steps = @(
        @{
            Title      = 'Create the workspace'
            What       = 'Creates a pay-per-GB workspace with the given retention.'
            Why        = 'Diagnostic settings need a destination before you can create them.'
            Cmdlet     = 'New-AzOperationalInsightsWorkspace'
            Parameters = @{ Name = '{{WorkspaceName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}'; Sku = '{{Sku}}'; RetentionInDays = '{{RetentionDays}}' }
        }
    )
    Verify   = @('Get-AzOperationalInsightsWorkspace -Name {{WorkspaceName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, Location, Sku, retentionInDays, CustomerId')
    Rollback = @('Remove-AzOperationalInsightsWorkspace -Name {{WorkspaceName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Soft-deleted 14 days; add -ForceDelete to purge.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.operationalinsights/new-azoperationalinsightsworkspace')
    Status   = 'Untested'
}
