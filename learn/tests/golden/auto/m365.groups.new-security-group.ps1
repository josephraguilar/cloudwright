New-MgGroup -DisplayName 'AVD Users - Lab' -MailNickname 'avd-users-lab' -Description 'Users allowed to sign in to the lab AVD pool' -SecurityEnabled -MailEnabled:$false -GroupTypes @()
