@{
    Id      = 'm365.groups.new-security-group'
    Title   = 'Create an Entra security group'
    Summary = 'A security group is the unit you assign licenses, roles, app access, and AVD desktops to. Create the group, then add members in a separate task.'
    Learn   = @(
        'Security groups have no mailbox. If people need to email it, that is a Microsoft 365 group or a distribution list, a different task.'
        'MailNickname is required by Graph even for security groups. It must be unique and have no spaces.'
        'Assigned membership is explicit. Dynamic membership (a rule) is a different task and needs Entra ID P1.'
    )
    Requires = @{
        Auth    = 'Graph'
        Modules = @('Microsoft.Graph.Groups')
        Scopes  = @('Group.ReadWrite.All')
        Roles   = @('Groups Administrator (or User Administrator / Global Administrator)')
    }
    Fields = @(
        @{
            Name     = 'DisplayName'
            Label    = 'Group display name'
            Help     = 'The name shown in portals and pickers. Does not have to be unique, but should be.'
            Type     = 'String'
            Required = $true
            Pattern  = '^.{1,256}$'
            Example  = 'AVD Users - Lab'
        }
        @{
            Name     = 'MailNickname'
            Label    = 'Mail nickname (no spaces, unique in the tenant)'
            Help     = 'The alias: the part of the address before the @, and the value Exchange uses internally to name the object. Required by Graph even for security groups that will never have a mailbox. Letters, digits, dots, hyphens, underscores; no spaces; unique in the tenant.'
            Type     = 'String'
            Required = $true
            Pattern  = '^[A-Za-z0-9._-]{1,64}$'
            Example  = 'avd-users-lab'
        }
        @{
            Name     = 'Description'
            Label    = 'Description (blank for none)'
            Help     = 'Free text shown in the portal. Say what the group grants and who owns it.'
            Type     = 'String'
            Required = $false
            Example  = 'Users allowed to sign in to the lab AVD pool'
        }
    )
    Steps = @(
        @{
            Title      = 'Create the group'
            What       = 'POST /groups with securityEnabled true and mailEnabled false. Returns the new group with its Id.'
            Why        = 'The object Id that comes back is what every later assignment (license, role, AVD app group) needs. Keep it.'
            Cmdlet     = 'New-MgGroup'
            Parameters = @{
                DisplayName     = '{{DisplayName}}'
                MailNickname    = '{{MailNickname}}'
                Description     = '{{Description}}'
                SecurityEnabled = '$true'
                MailEnabled     = '$false'
                GroupTypes      = '@()'
            }
            ParameterOrder = @('DisplayName', 'MailNickname', 'Description', 'SecurityEnabled', 'MailEnabled', 'GroupTypes')
            Fixed          = @('GroupTypes', 'MailEnabled', 'SecurityEnabled')
            Output         = 'group'
        }
    )
    Verify   = @('Get-MgGroup -Filter {{DisplayName:filter:displayName}} | Format-List Id, DisplayName, MailNickname, SecurityEnabled, CreatedDateTime')
    Rollback = @('Remove-MgGroup -GroupId $group.Id    # Soft-deleted for 30 days; restore from Entra admin center > Groups > Deleted groups.')
    Docs     = @(
        'https://learn.microsoft.com/powershell/module/microsoft.graph.groups/new-mggroup'
        'https://learn.microsoft.com/graph/api/group-post-groups'
    )
    Status   = 'Untested'
}
