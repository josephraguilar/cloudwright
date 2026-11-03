@{
    Id      = 'm365.groups.add-owner'
    Title   = 'Add an owner to a group'
    Summary = 'Owners can manage membership without an admin role. Every group should have at least two.'
    Learn   = @(
        'Owners of Microsoft 365 groups also own the Team, SharePoint site, and Planner behind it.'
        'Owner is set by reference (@odata.id), like manager.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Groups', 'Microsoft.Graph.Users'); Scopes = @('Group.ReadWrite.All'); Roles = @('Groups Administrator, or existing owner') }
    Prerequisites = @('m365.groups.new-security-group')
    Fields = @(
        @{ Name = 'GroupId'; Label = 'Group'; Help = 'The Entra group. The list comes from Get-MgGroup when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgGroup'; Parameters = @{ All = '$true' }; Display = 'DisplayName'; Value = 'Id'; Auth = 'Graph' } }
        @{ Name = 'UserId'; Label = 'New owner'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title = 'Add the owner'
            What  = 'POST /groups/{id}/owners/$ref with the user''s object URL.'
            Why   = 'Delegates membership management to the business.'
            Raw   = @('New-MgGroupOwnerByRef -GroupId {{GroupId}} -BodyParameter @{ ''@odata.id'' = "https://graph.microsoft.com/v1.0/users/$((Get-MgUser -UserId {{UserId}}).Id)" }')
        }
    )
    Verify   = @('Get-MgGroupOwner -GroupId {{GroupId}} | Select-Object Id, @{ n = ''Owner''; e = { $_.AdditionalProperties.userPrincipalName } }')
    Rollback = @('Remove-MgGroupOwnerByRef -GroupId {{GroupId}} -DirectoryObjectId (Get-MgUser -UserId {{UserId}}).Id')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.groups/new-mggroupownerbyref')
    Status   = 'Untested'
}
