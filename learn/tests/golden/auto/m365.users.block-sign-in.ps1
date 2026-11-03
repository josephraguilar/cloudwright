Update-MgUser -UserId 'sample-userid' -AccountEnabled:$false
Revoke-MgUserSignInSession -UserId 'sample-userid'
