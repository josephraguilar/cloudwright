Update-MgGroup -GroupId 'sample-groupid' -GroupTypes @('DynamicMembership') -MembershipRule '(user.department -eq "Sales") -and (user.accountEnabled -eq true)' -MembershipRuleProcessingState 'On'
