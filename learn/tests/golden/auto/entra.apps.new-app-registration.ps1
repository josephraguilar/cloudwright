New-MgApplication -DisplayName 'automation-hudu-sync' -SignInAudience 'AzureADMyOrg'
New-MgServicePrincipal -AppId (Get-MgApplication -Filter 'displayName eq ''automation-hudu-sync''').AppId
