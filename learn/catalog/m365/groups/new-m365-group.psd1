@{
    Id      = 'm365.groups.new-m365-group'
    Title   = 'Create a Microsoft 365 group'
    Summary = 'A Unified group: shared mailbox, calendar, SharePoint site, and optionally a Team. The collaboration group, as opposed to a security group.'
    Learn   = @(
        'GroupTypes Unified plus MailEnabled true is what makes it a Microsoft 365 group. SecurityEnabled false is the default for these, though it can also be true.'
        'Private groups need an owner to add members. Public groups let anyone join.'
        'Turn it into a Team afterwards with New-MgTeam -GroupId (needs the Teams module or Graph Teams cmdlets).'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Groups'); Scopes = @('Group.ReadWrite.All'); Roles = @('Groups Administrator') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'DisplayName'; Label = 'Group display name'; Help = 'The human-readable name shown in portals and address lists.'; Type = 'String'; Required = $true; Example = 'Project Falcon' }
        @{ Name = 'MailNickname'; Label = 'Mail nickname (becomes the email alias)'; Help = 'The alias: the part of the address before the @, and the value Exchange uses internally to name the object. Required by Graph even for security groups that will never have a mailbox. Letters, digits, dots, hyphens, underscores; no spaces; unique in the tenant.'; Type = 'String'; Required = $true; Pattern = '^[A-Za-z0-9._-]{1,64}$'; Example = 'project-falcon' }
        @{ Name = 'Visibility'; Label = 'Visibility'; Help = 'Private = content is only visible to members and someone has to add you (an owner, or an admin). Public = anyone in the tenant can find the group, read its content, and join themselves. Most working groups should be Private.'; Type = 'Choice'; Required = $true; Default = 'Private'; Options = @('Private', 'Public') }
        @{ Name = 'Description'; Label = 'Description'; Help = 'Free-text description shown in the portal.'; Type = 'String'; Required = $false }
    )
    Steps = @(
        @{
            Title      = 'Create the group'
            What       = 'POST /groups with groupTypes Unified.'
            Why        = 'Exchange and SharePoint provision the mailbox and site in the background.'
            Cmdlet     = 'New-MgGroup'
            Parameters = @{ DisplayName = '{{DisplayName}}'; MailNickname = '{{MailNickname}}'; Description = '{{Description}}'; Visibility = '{{Visibility}}'; GroupTypes = '@(''Unified'')'; MailEnabled = '$true'; SecurityEnabled = '$false' }
            ParameterOrder = @('DisplayName', 'MailNickname', 'Description', 'Visibility', 'GroupTypes', 'MailEnabled', 'SecurityEnabled')
            Fixed          = @('GroupTypes', 'MailEnabled', 'SecurityEnabled')
        }
    )
    Verify   = @('Get-MgGroup -Filter "mailNickname eq ''{{MailNickname:raw}}''" | Format-List Id, DisplayName, Mail, Visibility, GroupTypes')
    Rollback = @('Remove-MgGroup -GroupId (Get-MgGroup -Filter "mailNickname eq ''{{MailNickname:raw}}''").Id    # Soft-deleted 30 days.')
    Docs     = @('https://learn.microsoft.com/powershell/module/microsoft.graph.groups/new-mggroup')
    Status   = 'Untested'
}
