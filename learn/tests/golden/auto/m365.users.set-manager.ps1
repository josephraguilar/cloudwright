Set-MgUserManagerByRef -UserId 'sample-userid' -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$((Get-MgUser -UserId 'sample-managerid').Id)" }
