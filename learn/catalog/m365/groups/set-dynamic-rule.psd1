@{
    Id      = 'm365.groups.set-dynamic-rule'
    Title   = 'Make a group dynamic (membership rule)'
    Summary = 'Converts an assigned group to rule-based membership. Entra evaluates the rule continuously; nobody adds members by hand again.'
    Learn   = @(
        'Needs Entra ID P1 for every member. Rules use the attribute syntax (user.department -eq "Sales") -and (user.accountEnabled -eq true).'
        'Switching to dynamic wipes the current assigned members and replaces them with the rule result. Check the rule in the portal''s Validate Rules tab first.'
        'MembershipRuleProcessingState Paused keeps the rule but stops evaluation.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Groups'); Scopes = @('Group.ReadWrite.All'); Roles = @('Groups Administrator') }
    Prerequisites = @('m365.groups.new-security-group')
    Fields = @(
        @{ Name = 'GroupId'; Label = 'Group'; Help = 'The Entra group. The list comes from Get-MgGroup when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgGroup'; Parameters = @{ All = '$true' }; Display = 'DisplayName'; Value = 'Id'; Auth = 'Graph' } }
        @{ Name = 'Rule'; Label = 'Membership rule'; Help = 'Dynamic membership rule syntax: (user.property -operator "value"), combined with -and / -or. Properties include department, jobTitle, companyName, country, accountEnabled, userType; operators -eq, -ne, -contains, -startsWith, -match. Example: (user.department -eq "Sales") -and (user.accountEnabled -eq true). Needs an Entra ID P1 licence per member. Validate in the portal before saving; converting a group wipes its assigned members.'; Type = 'String'; Required = $true; Example = '(user.department -eq "Sales") -and (user.accountEnabled -eq true)' }
        @{ Name = 'ProcessingState'; Label = 'Rule processing'; Help = 'On = Entra evaluates the rule now and re-evaluates whenever a user attribute changes, adding and removing members automatically. Paused = the rule is saved but not applied, useful for staging a rule change. Membership does not update while paused.'; Type = 'Choice'; Required = $true; Default = 'On'; Options = @(@{ Display = 'On (evaluate now and continuously)'; Value = 'On' }, @{ Display = 'Paused (save the rule, do not evaluate yet)'; Value = 'Paused' }) }
    )
    Steps = @(
        @{
            Title      = 'Set the rule and turn processing on'
            What       = 'PATCH groupTypes to DynamicMembership with the rule.'
            Why        = 'Membership becomes a function of user attributes.'
            Cmdlet     = 'Update-MgGroup'
            Parameters = @{ GroupId = '{{GroupId}}'; GroupTypes = '@(''DynamicMembership'')'; MembershipRule = '{{Rule}}'; MembershipRuleProcessingState = '{{ProcessingState}}' }
            ParameterOrder = @('GroupId', 'GroupTypes', 'MembershipRule', 'MembershipRuleProcessingState')
            Fixed          = @('GroupTypes')
        }
    )
    Verify   = @('Get-MgGroup -GroupId {{GroupId}} -Property DisplayName, GroupTypes, MembershipRule, MembershipRuleProcessingState | Format-List DisplayName, GroupTypes, MembershipRule, MembershipRuleProcessingState')
    Rollback = @('Update-MgGroup -GroupId {{GroupId}} -GroupTypes @() -MembershipRuleProcessingState ''Paused''    # Back to assigned; members at that moment stay.')
    Docs     = @('https://learn.microsoft.com/entra/identity/users/groups-dynamic-membership')
    Status   = 'Untested'
}
