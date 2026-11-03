@{
    Id      = 'm365.groups.list-members'
    Title   = 'List the members of a group'
    Summary = 'Every user member with display name and UPN. Nested groups and devices are not expanded.'
    Learn   = @(
        'Get-MgGroupMember returns directory objects with most properties in AdditionalProperties. Get-MgGroupMemberAsUser casts to users so DisplayName and UserPrincipalName are real columns.'
        'Add -Top or drop -All for very large groups.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Groups'); Scopes = @('GroupMember.Read.All'); Roles = @('Any user can read most groups') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'GroupId'; Label = 'Group'; Help = 'The Entra group. The list comes from Get-MgGroup when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgGroup'; Parameters = @{ All = '$true' }; Display = 'DisplayName'; Value = 'Id'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title = 'List user members'
            What  = 'Pages through all members cast as users.'
            Why   = 'Access reviews and offboarding both start with this.'
            Fixed = @('All')
            Raw   = @('Get-MgGroupMemberAsUser -GroupId {{GroupId}} -All | Sort-Object DisplayName | Format-Table DisplayName, UserPrincipalName, AccountEnabled -AutoSize')
        }
    )
    Docs   = @('https://learn.microsoft.com/powershell/module/microsoft.graph.groups/get-mggroupmemberasuser')
    Status = 'Untested'
}
