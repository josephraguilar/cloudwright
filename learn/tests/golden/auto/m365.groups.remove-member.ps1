Remove-MgGroupMemberByRef -GroupId 'sample-groupid' -DirectoryObjectId (Get-MgUser -UserId 'sample-userid').Id
