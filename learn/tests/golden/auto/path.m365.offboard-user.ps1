Update-MgUser -UserId 'sample-userid' -AccountEnabled:$false
Revoke-MgUserSignInSession -UserId 'sample-userid'

Set-Mailbox -Identity 'sample-userid' -ForwardingSmtpAddress 'manager@contoso.com' -DeliverToMailboxAndForward $true

Set-Mailbox -Identity 'sample-userid' -Type 'Shared'

Set-MgUserLicense -UserId 'sample-userid' -AddLicenses @() -RemoveLicenses @('sample-skuid')
