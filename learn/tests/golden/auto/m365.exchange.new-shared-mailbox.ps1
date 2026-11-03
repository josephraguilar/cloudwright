New-Mailbox -Shared -Name 'Support' -DisplayName 'Support' -Alias 'support' -PrimarySmtpAddress 'support@contoso.com'
Add-MailboxPermission -Identity 'support@contoso.com' -User 'sample-fullaccessuser' -AccessRights 'FullAccess' -AutoMapping $true
Add-RecipientPermission -Identity 'support@contoso.com' -Trustee 'sample-fullaccessuser' -AccessRights 'SendAs' -Confirm:$false
