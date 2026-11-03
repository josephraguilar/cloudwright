Connect-AzAccount
Get-AzSubscription | Where-Object State -eq 'Enabled' | Format-Table Name, Id, TenantId
Set-AzContext -Subscription '00000000-0000-0000-0000-000000000001'
