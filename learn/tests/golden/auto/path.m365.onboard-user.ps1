New-MgUser -DisplayName 'Jane Doe' -GivenName 'Jane' -Surname 'Doe' -UserPrincipalName 'jane.doe@contoso.com' -MailNickname 'jane.doe' -UsageLocation 'US' -JobTitle 'sample-jobtitle' -Department 'sample-department' -AccountEnabled -PasswordProfile @{ Password = (Read-Host -Prompt 'Initial password'); ForceChangePasswordNextSignIn = $true }

Set-MgUserLicense -UserId 'jane.doe@contoso.com' -AddLicenses @(@{ SkuId = 'sample-skuid' }) -RemoveLicenses @()

New-MgGroupMember -GroupId 'sample-groupid' -DirectoryObjectId (Get-MgUser -UserId 'jane.doe@contoso.com').Id

Set-MgUserManagerByRef -UserId 'jane.doe@contoso.com' -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$((Get-MgUser -UserId 'sample-managerid').Id)" }
