New-MgGroupOwnerByRef -GroupId 'sample-groupid' -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$((Get-MgUser -UserId 'sample-userid').Id)" }
