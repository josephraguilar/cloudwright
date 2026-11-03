Update-MgUser -UserId 'sample-userid' -PasswordProfile @{ Password = (Read-Host -Prompt 'New temporary password'); ForceChangePasswordNextSignIn = $true }
