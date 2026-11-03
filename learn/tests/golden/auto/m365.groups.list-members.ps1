Get-MgGroupMemberAsUser -GroupId 'sample-groupid' -All | Sort-Object DisplayName | Format-Table DisplayName, UserPrincipalName, AccountEnabled -AutoSize
