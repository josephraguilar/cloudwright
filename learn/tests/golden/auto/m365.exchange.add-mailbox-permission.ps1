Add-MailboxPermission -Identity 'sample-mailbox' -User 'sample-user' -AccessRights 'FullAccess' -AutoMapping $true
Add-RecipientPermission -Identity 'sample-mailbox' -Trustee 'sample-user' -AccessRights 'SendAs' -Confirm:$false
Set-Mailbox -Identity 'sample-mailbox' -GrantSendOnBehalfTo @{ Add = 'sample-user' }
