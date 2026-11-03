@{
    Id      = 'entra.ca.new-policy-report-only'
    Title   = 'Create a Conditional Access policy requiring MFA (report-only)'
    Summary = 'A policy that would require MFA for a group on all cloud apps, created in report-only mode so you can read the sign-in log impact before enforcing it.'
    Learn   = @(
        'Never create a CA policy enabled from a script. Report-only for a week, review the Conditional Access insights workbook, then flip state to enabled in the portal.'
        'Always exclude a break-glass account or group. A policy that locks out every admin is recovered only by Microsoft support.'
        'includeApplications All plus grantControls mfa is the baseline policy. Add conditions (locations, platforms, risk) in later iterations.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Identity.SignIns'); Scopes = @('Policy.ReadWrite.ConditionalAccess', 'Policy.Read.All'); Roles = @('Conditional Access Administrator') }
    Prerequisites = @('m365.groups.new-security-group')
    Fields = @(
        @{ Name = 'PolicyName'; Label = 'Policy name'; Help = 'The policy name. Use a numbering convention so policies sort and are easy to reference.'; Type = 'String'; Required = $true; Example = 'CA001 - Require MFA - Pilot group (report-only)' }
        @{ Name = 'GroupId'; Label = 'Group the policy applies to'; Help = 'The Entra group. The list comes from Get-MgGroup when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgGroup'; Parameters = @{ All = '$true' }; Display = 'DisplayName'; Value = 'Id'; Auth = 'Graph' } }
        @{ Name = 'ExcludeGroupId'; Label = 'Break-glass / exclusion group'; Help = 'Users exempt from the policy. Every Conditional Access policy should exclude a break-glass group: one or two cloud-only emergency accounts with long random passwords stored offline, so a broken policy cannot lock every administrator out. Also exclude service accounts that cannot do MFA.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgGroup'; Parameters = @{ All = '$true' }; Display = 'DisplayName'; Value = 'Id'; Auth = 'Graph' } }
    )
    Steps = @(
        @{
            Title = 'Create the policy in report-only mode'
            What  = 'POST a conditionalAccessPolicy: include group, exclude group, all apps, all client types, grant requires mfa, state enabledForReportingButNotEnforced.'
            Why   = 'Report-only logs what would have happened without affecting anyone.'
            Raw   = @('New-MgIdentityConditionalAccessPolicy -BodyParameter @{ displayName = {{PolicyName}}; state = ''enabledForReportingButNotEnforced''; conditions = @{ users = @{ includeGroups = @({{GroupId}}); excludeGroups = @({{ExcludeGroupId}}) }; applications = @{ includeApplications = @(''All'') }; clientAppTypes = @(''all'') }; grantControls = @{ operator = ''OR''; builtInControls = @(''mfa'') } }')
        }
    )
    Verify   = @('Get-MgIdentityConditionalAccessPolicy -Filter {{PolicyName:filter:displayName}} | Select-Object Id, DisplayName, State, CreatedDateTime')
    Rollback = @('Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId (Get-MgIdentityConditionalAccessPolicy -Filter {{PolicyName:filter:displayName}}).Id')
    Docs     = @('https://learn.microsoft.com/graph/api/conditionalaccessroot-post-policies', 'https://learn.microsoft.com/entra/identity/conditional-access/howto-conditional-access-insights-reporting')
    Status   = 'Untested'
}
