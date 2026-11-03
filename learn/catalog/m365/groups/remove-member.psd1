@{
    Id      = 'm365.groups.remove-member'
    Title   = 'Remove a user from a group'
    Summary = 'Removes one member. Anything assigned through the group (licence, app, desktop) is withdrawn within minutes.'
    Learn   = @(
        'Removing a licence-bearing group membership puts the mailbox into the 30-day grace, same as removing the licence directly.'
        'Owners are separate from members; removing a member who is also an owner leaves them as owner.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Groups', 'Microsoft.Graph.Users'); Scopes = @('GroupMember.ReadWrite.All'); Roles = @('Groups Administrator, or owner of the group') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'GroupId'; Label = 'Group'; Help = 'The Entra group. The list comes from Get-MgGroup when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgGroup'; Parameters = @{ All = '$true' }; Display = 'DisplayName'; Value = 'Id'; Auth = 'Graph' } }
        @{ Name = 'UserId'; Label = 'User'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title = 'Remove the member'
            What  = 'DELETE /groups/{id}/members/{userId}/$ref.'
            Why   = 'Immediate; no confirmation prompt from Graph.'
            Raw   = @('Remove-MgGroupMemberByRef -GroupId {{GroupId}} -DirectoryObjectId (Get-MgUser -UserId {{UserId}}).Id')
        }
    )
    Verify   = @('Get-MgGroupMemberAsUser -GroupId {{GroupId}} -All | Select-Object DisplayName, UserPrincipalName')
    Rollback = @('New-MgGroupMember -GroupId {{GroupId}} -DirectoryObjectId (Get-MgUser -UserId {{UserId}}).Id')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.groups/remove-mggroupmemberbyref')
    Status   = 'Untested'
}
