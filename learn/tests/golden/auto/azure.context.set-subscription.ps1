Connect-AzAccount -Tenant '00000000-0000-0000-0000-000000000000'
Get-AzSubscription | Where-Object State -eq 'Enabled' | Format-Table Name, Id, TenantId
Set-AzContext -Subscription 'sample-subscriptionid'
