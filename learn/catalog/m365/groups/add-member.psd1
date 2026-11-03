@{
    Id      = 'm365.groups.add-member'
    Title   = 'Add a user to a group'
    Summary = 'Adds one member to a security or Microsoft 365 group. Licences, app access, and AVD desktops assigned to the group follow within minutes.'
    Learn   = @(
        'Members are added by directory object Id, so the user is looked up by UPN first.'
        'Dynamic groups reject manual adds; change the rule or the user attribute instead.'
        'Mail-enabled security groups and distribution lists are managed in Exchange, not here.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Groups', 'Microsoft.Graph.Users'); Scopes = @('GroupMember.ReadWrite.All'); Roles = @('Groups Administrator, or owner of the group') }
    Prerequisites = @('m365.groups.new-security-group')
    Fields = @(
        @{ Name = 'GroupId'; Label = 'Group'; Help = 'The Entra group. The list comes from Get-MgGroup when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgGroup'; Parameters = @{ All = '$true' }; Display = 'DisplayName'; Value = 'Id'; Auth = 'Graph' } }
        @{ Name = 'UserId'; Label = 'User'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title = 'Add the member'
            What  = 'POST /groups/{id}/members/$ref with the user''s object Id.'
            Why   = 'Group membership is the unit everything else is assigned to.'
            Raw   = @('New-MgGroupMember -GroupId {{GroupId}} -DirectoryObjectId (Get-MgUser -UserId {{UserId}}).Id')
        }
    )
    Verify   = @('Get-MgGroupMemberAsUser -GroupId {{GroupId}} -All | Select-Object DisplayName, UserPrincipalName')
    Rollback = @('Remove-MgGroupMemberByRef -GroupId {{GroupId}} -DirectoryObjectId (Get-MgUser -UserId {{UserId}}).Id')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.groups/new-mggroupmember')
    Status   = 'Untested'
}
