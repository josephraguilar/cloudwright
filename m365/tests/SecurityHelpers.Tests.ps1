[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Write stubs are global (like the real EXO and Graph commands) and record into a global log.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Stubs of Exchange and Graph cmdlets; Invoke-M365Change does the asking.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameter lists mirror the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build objects; they change nothing.')]
param()

# Legacy domain behavior runs only against the fake APIs in this test file.
# Mock the release policy here so these tests still exercise plan matching and
# mutation semantics. Safety.Tests.ps1 and EndToEnd.Tests.ps1 use the real policy.
BeforeAll {
    $modules = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules'
    Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
    Import-Module (Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1') -Force
    $script:ManifestPath = Join-Path $modules 'SecurityHelpers' 'SecurityHelpers.psd1'
    Import-Module $script:ManifestPath -Force
    $script:Baseline = Get-M365SecurityBaseline -Path (Join-Path $PSScriptRoot '..' 'config' 'baselines' 'security.example.json')
    $env:M365_TOOLKIT_LOG_PATH = Join-Path $TestDrive 'logs'

    # Graph and Exchange are not installed in CI. Reads are stubbed in the module's scope so
    # Pester can mock them; writes are global recording stubs, as the real EXO and Graph
    # commands are global commands.
    InModuleScope SecurityHelpers {
        function script:Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy { [CmdletBinding()] param() }
        function script:Get-MgIdentityConditionalAccessPolicy { [CmdletBinding()] param([switch]$All) }
        function script:Get-MgDomain { [CmdletBinding()] param([switch]$All) }
        function script:Get-MgPolicyAuthorizationPolicy { [CmdletBinding()] param() }
        function script:Get-MgDirectoryRole { [CmdletBinding()] param($Filter) }
        function script:Get-MgDirectoryRoleMember { [CmdletBinding()] param($DirectoryRoleId, [switch]$All) }
        function script:Get-MgUser { [CmdletBinding()] param($Filter, $UserId, $Property) }
        function script:Get-MgOrganization { [CmdletBinding()] param() }
        function script:Get-AdminAuditLogConfig { [CmdletBinding()] param() }
        function script:Get-OrganizationConfig { [CmdletBinding()] param() }
        function script:Get-HostedOutboundSpamFilterPolicy { [CmdletBinding()] param($Identity) }
        function script:Get-HostedOutboundSpamFilterRule { [CmdletBinding()] param() }
        function script:Get-ExternalInOutlook { [CmdletBinding()] param() }
        function script:Get-TransportConfig { [CmdletBinding()] param() }
        function script:Get-AntiPhishPolicy { [CmdletBinding()] param() }
        function script:Get-AcceptedDomain { [CmdletBinding()] param() }
        function script:Get-Mailbox { [CmdletBinding()] param($RecipientTypeDetails, $ResultSize) }
        function script:Get-DistributionGroupMember { [CmdletBinding()] param($Identity, $ResultSize) }
    }
    InModuleScope ExchangeHelpers {
        function script:Get-Recipient { [CmdletBinding()] param($Identity) }
        function script:Get-MailContact { [CmdletBinding()] param($Identity) }
    }
    $global:SecWriteLog = [System.Collections.Generic.List[object]]::new()
    function global:Invoke-SecTestWrite { param([string]$Name, [hashtable]$Bound) $c = @{}; foreach ($k in $Bound.Keys) { $c[$k] = $Bound[$k] }; $global:SecWriteLog.Add([pscustomobject]@{ Command = $Name; Params = $c }) }
    function global:Set-TransportConfig { [CmdletBinding(SupportsShouldProcess)] param($SmtpClientAuthenticationDisabled) Invoke-SecTestWrite 'Set-TransportConfig' $PSBoundParameters }
    function global:Set-ExternalInOutlook { [CmdletBinding(SupportsShouldProcess)] param($Enabled) Invoke-SecTestWrite 'Set-ExternalInOutlook' $PSBoundParameters }
    function global:Set-AdminAuditLogConfig { [CmdletBinding(SupportsShouldProcess)] param($UnifiedAuditLogIngestionEnabled) Invoke-SecTestWrite 'Set-AdminAuditLogConfig' $PSBoundParameters }
    function global:Set-OrganizationConfig { [CmdletBinding(SupportsShouldProcess)] param($AuditDisabled) Invoke-SecTestWrite 'Set-OrganizationConfig' $PSBoundParameters }
    function global:Set-HostedOutboundSpamFilterPolicy { [CmdletBinding(SupportsShouldProcess)] param($Identity, $AutoForwardingMode) Invoke-SecTestWrite 'Set-HostedOutboundSpamFilterPolicy' $PSBoundParameters }
    function global:Update-MgPolicyIdentitySecurityDefaultEnforcementPolicy { [CmdletBinding(SupportsShouldProcess)] param([switch]$IsEnabled) Invoke-SecTestWrite 'Update-MgPolicyIdentitySecurityDefaultEnforcementPolicy' $PSBoundParameters }
    $script:SecWrites = 'Set-TransportConfig', 'Set-ExternalInOutlook', 'Set-AdminAuditLogConfig', 'Set-OrganizationConfig', 'Set-HostedOutboundSpamFilterPolicy', 'Update-MgPolicyIdentitySecurityDefaultEnforcementPolicy'

    $script:FakeSettings = [pscustomobject]@{
        msp               = [pscustomobject]@{ supportEmail = 'support@msp.example' }
        breakGlass        = [pscustomobject]@{ upnPrefix = 'breakglass' }
        adminAccounts     = @([pscustomobject]@{ upnPrefix = 'mspadmin' })
        distributionLists = [pscustomobject]@{ it = 'IT'; alerts = 'MSPalerts' }
    }
    function New-CaPolicy {
        param([string]$Name, [string]$State = 'enabled', [string[]]$Users = @('All'), [string[]]$Apps = @('All'), [string[]]$Clients = @('all'), [string[]]$Controls = @('mfa'), [string[]]$Exclude = @())
        [pscustomobject]@{
            DisplayName   = $Name; State = $State
            Conditions    = [pscustomobject]@{ Users = [pscustomobject]@{ IncludeUsers = $Users; ExcludeUsers = $Exclude }; Applications = [pscustomobject]@{ IncludeApplications = $Apps }; ClientAppTypes = $Clients }
            GrantControls = [pscustomobject]@{ BuiltInControls = $Controls; AuthenticationStrength = [pscustomobject]@{ Id = $null } }
        }
    }
}
AfterAll {
    Remove-Item env:M365_TOOLKIT_LOG_PATH -ErrorAction SilentlyContinue
    foreach ($w in $script:SecWrites + 'Invoke-SecTestWrite') { Remove-Item "Function:\$w" -ErrorAction SilentlyContinue }
    Remove-Variable -Name SecWriteLog -Scope Global -ErrorAction SilentlyContinue
}

Describe 'SecurityHelpers' {
    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
    }

    It 'has a valid manifest' { { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw }
    It 'loads the example baseline with every check complete' {
        $script:Baseline.checks.Count | Should -Be 25
        ($script:Baseline.checks | Where-Object { $_.title -like 'MSP:*' }).Count | Should -Be 8
        foreach ($c in $script:Baseline.checks) { $c.remediation | Should -Not -BeNullOrEmpty -Because $c.id }
    }
    It 'names remediation scripts with their current parameters (-State, not bare booleans)' {
        ($script:Baseline.checks | Where-Object { $_.remediation -match '-Enabled \$|-Disabled \$' }) | Should -BeNullOrEmpty
    }
    It 'makes no tenant write outside Invoke-M365Change' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'SecurityHelpers' 'SecurityHelpers.psm1'), [ref]$null, [ref]$null)
        $direct = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $script:SecWrites -contains $n.GetCommandName() }, $true)
        @($direct | ForEach-Object { "$($_.GetCommandName()) at line $($_.Extent.StartLineNumber)" }) | Should -BeNullOrEmpty
    }

    Context 'Compare-M365SecurityBaseline' {
        It 'passes booleans that match and fails ones that do not' {
            $facts = @{ mfaEnforced = $true; legacyAuthBlocked = $false }
            $rows = Compare-M365SecurityBaseline -Facts $facts -Baseline $script:Baseline
            ($rows | Where-Object Id -eq 'mfaEnforced').Result | Should -Be 'Pass'
            ($rows | Where-Object Id -eq 'legacyAuthBlocked').Result | Should -Be 'Fail'
        }
        It 'evaluates min/max ranges' {
            (Compare-M365SecurityBaseline -Facts @{ globalAdminCount = 3 } -Baseline $script:Baseline | Where-Object Id -eq 'globalAdminCount').Result | Should -Be 'Pass'
            (Compare-M365SecurityBaseline -Facts @{ globalAdminCount = 7 } -Baseline $script:Baseline | Where-Object Id -eq 'globalAdminCount').Result | Should -Be 'Fail'
            (Compare-M365SecurityBaseline -Facts @{ globalAdminCount = 1 } -Baseline $script:Baseline | Where-Object Id -eq 'globalAdminCount').Result | Should -Be 'Fail'
        }
        It 'marks missing facts Unknown and carries collector errors into Actual' {
            $rows = Compare-M365SecurityBaseline -Facts @{} -Baseline $script:Baseline -Errors @{ unifiedAuditLog = 'no Exchange session' }
            ($rows | Where-Object Id -eq 'unifiedAuditLog').Result | Should -Be 'Unknown'
            ($rows | Where-Object Id -eq 'unifiedAuditLog').Actual | Should -Match 'no Exchange session'
            ($rows | Where-Object Id -eq 'dkimAllDomains').Actual | Should -Be 'not collected'
        }
        It 'appends the <id>Detail fact to Actual' {
            $row = Compare-M365SecurityBaseline -Facts @{ autoForwardingBlocked = $false; autoForwardingBlockedDetail = 'not Off in: Sales (On)' } -Baseline $script:Baseline | Where-Object Id -eq 'autoForwardingBlocked'
            $row.Actual | Should -Be 'False (not Off in: Sales (On))'
        }
        It 'sorts failures first, by severity' {
            $facts = @{ mfaEnforced = $false; externalSenderTag = $false; unifiedAuditLog = $true; smtpAuthDisabled = $false }
            $rows = Compare-M365SecurityBaseline -Facts $facts -Baseline $script:Baseline
            $rows[0].Result | Should -Be 'Fail'; $rows[0].Severity | Should -Be 'High'
            ($rows | Where-Object Result -eq 'Fail')[-1].Severity | Should -Be 'Low'
            @($rows | Where-Object Result -eq 'Pass').Count | Should -Be 1
        }
    }

    Context 'Get-M365SecurityFact derived values (mocked Graph, Exchange skipped)' {
        BeforeEach {
            Mock -ModuleName SecurityHelpers Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy { [pscustomobject]@{ IsEnabled = $false } }
            Mock -ModuleName SecurityHelpers Get-MgDomain { @([pscustomobject]@{ Id = 'c.com'; IsVerified = $true; IsInitial = $false; PasswordValidityPeriodInDays = 90 }, [pscustomobject]@{ Id = 'c.onmicrosoft.com'; IsVerified = $true; IsInitial = $true; PasswordValidityPeriodInDays = 2147483647 }) }
            Mock -ModuleName SecurityHelpers Get-MgPolicyAuthorizationPolicy { [pscustomobject]@{ AllowedToUseSspr = $true; AllowInvitesFrom = 'everyone'; DefaultUserRolePermissions = [pscustomobject]@{ PermissionGrantPoliciesAssigned = @() } } }
            Mock -ModuleName SecurityHelpers Get-MgDirectoryRole { [pscustomobject]@{ Id = 'ga' } }
            Mock -ModuleName SecurityHelpers Get-MgDirectoryRoleMember { @([pscustomobject]@{ Id = '1'; AdditionalProperties = @{ userPrincipalName = 'a@c.com' } }, [pscustomobject]@{ Id = '2'; AdditionalProperties = @{ userPrincipalName = 'breakglass@c.onmicrosoft.com' } }) }
            Mock -ModuleName SecurityHelpers Get-MgUser { [pscustomobject]@{ Id = 'bg'; UserPrincipalName = 'breakglass@c.onmicrosoft.com' } }
            Mock -ModuleName SecurityHelpers Get-MgOrganization { [pscustomobject]@{ TechnicalNotificationMails = @('owner@c.com', 'support@msp.example') } }
        }
        It 'derives mfaEnforced and legacyAuthBlocked from CA when Security Defaults is off' {
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy {
                New-CaPolicy -Name 'MFA all' -Exclude 'bg'
                New-CaPolicy -Name 'Block legacy' -State 'enabledForReportingButNotEnforced' -Clients 'exchangeActiveSync', 'other' -Controls 'block'
            }
            $r = Get-M365SecurityFact -Settings $script:FakeSettings -SkipExchange
            $r.Facts.mfaEnforced | Should -BeTrue
            $r.Facts.legacyAuthBlocked | Should -BeFalse   # report-only policy does not count
            $r.Facts.passwordNeverExpires | Should -BeFalse
            $r.Facts.userConsentBlocked | Should -BeTrue
            $r.Facts.guestInviteRestricted | Should -BeFalse
            $r.Facts.globalAdminCount | Should -Be 2
            $r.Facts.breakGlassExists | Should -BeTrue
            $r.Facts.breakGlassIsGlobalAdmin | Should -BeTrue
            $r.Facts.breakGlassExcludedFromCA | Should -BeTrue   # only enabled policies count; the report-only one is ignored
            $r.Facts.technicalContactSet | Should -BeTrue
            $r.Facts.mspAdminExists | Should -BeTrue
            $r.Errors.Count | Should -Be 0
        }
        It 'looks for break-glass on the tenant''s initial (onmicrosoft) domain from Graph when none is passed' {
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy { }
            $null = Get-M365SecurityFact -Settings $script:FakeSettings -SkipExchange
            Should -Invoke -ModuleName SecurityHelpers Get-MgUser -Times 1 -Exactly -ParameterFilter { $Filter -eq "userPrincipalName eq 'breakglass@c.onmicrosoft.com'" }
        }
        It 'flags a break-glass account that an enabled CA policy does not exclude' {
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy {
                New-CaPolicy -Name 'MFA all' -Exclude 'bg'
                New-CaPolicy -Name 'Block legacy' -Clients 'exchangeActiveSync', 'other' -Controls 'block'
            }
            Mock -ModuleName SecurityHelpers Get-MgDirectoryRoleMember { @([pscustomobject]@{ Id = '1'; AdditionalProperties = @{ userPrincipalName = 'a@c.com' } }) }
            Mock -ModuleName SecurityHelpers Get-MgOrganization { [pscustomobject]@{ TechnicalNotificationMails = @() } }
            $r = Get-M365SecurityFact -Settings $script:FakeSettings -SkipExchange
            $r.Facts.legacyAuthBlocked | Should -BeTrue
            $r.Facts.breakGlassExcludedFromCA | Should -BeFalse
            $r.Facts.breakGlassNotExcludedFrom | Should -Be @('Block legacy')
            $r.Facts.breakGlassIsGlobalAdmin | Should -BeFalse
            $r.Facts.technicalContactSet | Should -BeFalse
            $rows = Compare-M365SecurityBaseline -Facts $r.Facts -Baseline $script:Baseline
            ($rows | Where-Object Id -eq 'breakGlassExcludedFromCA').Result | Should -Be 'Fail'
            ($rows | Where-Object Id -eq 'breakGlassExcludedFromCA').Actual | Should -Match 'not excluded from: Block legacy'
            ($rows | Where-Object Id -eq 'mspContactHidden').Result | Should -Be 'Unknown'
        }
        It 'reports every CA-derived fact as Unknown (never Pass or Fail) when Conditional Access cannot be read' {
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy { throw 'Insufficient privileges to complete the operation.' }
            $r = Get-M365SecurityFact -Settings $script:FakeSettings -SkipExchange
            $r.Facts.mfaEnforced | Should -BeNullOrEmpty
            $r.Facts.legacyAuthBlocked | Should -BeNullOrEmpty
            $r.Facts.breakGlassExcludedFromCA | Should -BeNullOrEmpty
            $rows = Compare-M365SecurityBaseline -Facts $r.Facts -Baseline $script:Baseline -Errors $r.Errors
            foreach ($id in 'mfaEnforced', 'legacyAuthBlocked', 'breakGlassExcludedFromCA') {
                ($rows | Where-Object Id -eq $id).Result | Should -Be 'Unknown' -Because $id
                ($rows | Where-Object Id -eq $id).Actual | Should -Match 'Insufficient privileges' -Because $id
            }
        }
        It 'still passes MFA and legacy auth on Security Defaults when CA cannot be read' {
            Mock -ModuleName SecurityHelpers Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy { [pscustomobject]@{ IsEnabled = $true } }
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy { throw 'Insufficient privileges' }
            $r = Get-M365SecurityFact -Settings $script:FakeSettings -SkipExchange
            $r.Facts.mfaEnforced | Should -BeTrue
            $r.Facts.legacyAuthBlocked | Should -BeTrue
        }
        It 'does not count MFA policies scoped to one app, one group, or browser only' {
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy {
                New-CaPolicy -Name 'MFA for Azure portal' -Apps '797f4846-ba00-4fd7-ba43-dac1f8f63013'
                New-CaPolicy -Name 'MFA for admins' -Users 'group-guid'
                New-CaPolicy -Name 'MFA in browsers' -Clients 'browser'
            }
            (Get-M365SecurityFact -Settings $script:FakeSettings -SkipExchange).Facts.mfaEnforced | Should -BeFalse
        }
        It 'does not count a legacy-auth block that covers only some users or apps' {
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy {
                New-CaPolicy -Name 'Block legacy (pilot)' -Users 'pilot-group' -Clients 'exchangeActiveSync', 'other' -Controls 'block'
                New-CaPolicy -Name 'Block legacy (EXO only)' -Apps '00000002-0000-0ff1-ce00-000000000000' -Clients 'exchangeActiveSync', 'other' -Controls 'block'
                New-CaPolicy -Name 'Block EAS only' -Clients 'exchangeActiveSync' -Controls 'block'
            }
            (Get-M365SecurityFact -Settings $script:FakeSettings -SkipExchange).Facts.legacyAuthBlocked | Should -BeFalse
        }
        It 'records collector errors instead of failing the whole audit, and does not guess MFA' {
            Mock -ModuleName SecurityHelpers Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy { throw 'Insufficient privileges' }
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy { @() }
            Mock -ModuleName SecurityHelpers Get-MgDomain { @() }
            Mock -ModuleName SecurityHelpers Get-MgPolicyAuthorizationPolicy { $null }
            Mock -ModuleName SecurityHelpers Get-MgDirectoryRole { $null }
            Mock -ModuleName SecurityHelpers Get-MgUser { $null }
            Mock -ModuleName SecurityHelpers Get-MgOrganization { $null }
            $r = Get-M365SecurityFact -Settings $script:FakeSettings -SkipExchange
            $r.Errors.Keys | Should -Contain 'securityDefaults'
            $r.Facts.securityDefaults | Should -BeNullOrEmpty
            $r.Facts.mfaEnforced | Should -BeNullOrEmpty   # Security Defaults unknown and no CA policy: cannot say
        }
        It 'reports break-glass checks Unknown when the account lookup fails' {
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy { }
            Mock -ModuleName SecurityHelpers Get-MgUser { throw 'Request throttled' }
            $r = Get-M365SecurityFact -Settings $script:FakeSettings -SkipExchange
            $r.Facts.breakGlassExists | Should -BeNullOrEmpty
            $r.Facts.breakGlassExcludedFromCA | Should -BeNullOrEmpty
        }
    }

    Context 'Get-M365SecurityFact Exchange facts' {
        BeforeEach {
            Mock -ModuleName SecurityHelpers Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy { [pscustomobject]@{ IsEnabled = $true } }
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy { }
            Mock -ModuleName SecurityHelpers Get-MgDomain { @() }
            Mock -ModuleName SecurityHelpers Get-MgPolicyAuthorizationPolicy { $null }
            Mock -ModuleName SecurityHelpers Get-MgDirectoryRole { $null }
            Mock -ModuleName SecurityHelpers Get-MgUser { $null }
            Mock -ModuleName SecurityHelpers Get-MgOrganization { $null }
            Mock -ModuleName SecurityHelpers Get-AdminAuditLogConfig { [pscustomobject]@{ UnifiedAuditLogIngestionEnabled = $true } }
            Mock -ModuleName SecurityHelpers Get-OrganizationConfig { [pscustomobject]@{ AuditDisabled = $false; OAuth2ClientProfileEnabled = $true } }
            Mock -ModuleName SecurityHelpers Get-ExternalInOutlook { [pscustomobject]@{ Enabled = $true } }
            Mock -ModuleName SecurityHelpers Get-TransportConfig { [pscustomobject]@{ SmtpClientAuthenticationDisabled = $true } }
            Mock -ModuleName SecurityHelpers Get-AntiPhishPolicy { [pscustomobject]@{ IsDefault = $true; EnableSpoofIntelligence = $true } }
            Mock -ModuleName SecurityHelpers Get-AcceptedDomain { [pscustomobject]@{ DomainName = 'c.onmicrosoft.com' } }
            Mock -ModuleName SecurityHelpers Get-Mailbox { }
            Mock -ModuleName SecurityHelpers Get-HostedOutboundSpamFilterPolicy { [pscustomobject]@{ Name = 'Default'; Identity = 'Default'; IsDefault = $true; AutoForwardingMode = 'Off' }; [pscustomobject]@{ Name = 'Sales'; Identity = 'Sales'; IsDefault = $false; AutoForwardingMode = 'On' } }
            Mock -ModuleName SecurityHelpers Get-HostedOutboundSpamFilterRule { [pscustomobject]@{ Name = 'Sales rule'; HostedOutboundSpamFilterPolicy = 'Sales'; State = 'Enabled' } }
            Mock -ModuleName ExchangeHelpers Get-Recipient { throw "Ex|Microsoft.Exchange.Configuration.Tasks.ManagementObjectNotFoundException|The operation couldn't be performed because object 'x' couldn't be found on 'NAM'." }
        }
        It 'fails auto-forwarding when an enabled custom outbound policy allows it, naming the policy' {
            $r = Get-M365SecurityFact -Settings $script:FakeSettings
            $r.Facts.autoForwardingBlocked | Should -BeFalse
            $row = Compare-M365SecurityBaseline -Facts $r.Facts -Baseline $script:Baseline | Where-Object Id -eq 'autoForwardingBlocked'
            $row.Result | Should -Be 'Fail'
            $row.Actual | Should -Match 'Sales \(On\)'
        }
        It 'ignores a custom policy whose rule is disabled' {
            Mock -ModuleName SecurityHelpers Get-HostedOutboundSpamFilterRule { [pscustomobject]@{ Name = 'Sales rule'; HostedOutboundSpamFilterPolicy = 'Sales'; State = 'Disabled' } }
            (Get-M365SecurityFact -Settings $script:FakeSettings).Facts.autoForwardingBlocked | Should -BeTrue
        }
        It 'reports shared-mailbox sign-in Unknown (not Pass) when an account cannot be read' {
            Mock -ModuleName SecurityHelpers Get-Mailbox { [pscustomobject]@{ PrimarySmtpAddress = 'info@c.com'; ExternalDirectoryObjectId = 'id-1' } }
            Mock -ModuleName SecurityHelpers Get-MgUser { if ($UserId) { throw 'Request throttled' } }
            $r = Get-M365SecurityFact -Settings $script:FakeSettings
            $r.Facts.sharedMailboxSignInBlocked | Should -BeNullOrEmpty
            $r.Errors['sharedMailboxSignInBlocked'] | Should -Match 'info@c.com'
        }
        It 'passes shared-mailbox sign-in when there are no shared mailboxes, and fails one with sign-in on' {
            (Get-M365SecurityFact -Settings $script:FakeSettings).Facts.sharedMailboxSignInBlocked | Should -BeTrue
            Mock -ModuleName SecurityHelpers Get-Mailbox { [pscustomobject]@{ PrimarySmtpAddress = 'info@c.com'; ExternalDirectoryObjectId = 'id-1' } }
            Mock -ModuleName SecurityHelpers Get-MgUser { if ($UserId) { [pscustomobject]@{ AccountEnabled = $true; UserPrincipalName = 'info@c.com' } } }
            (Get-M365SecurityFact -Settings $script:FakeSettings).Facts.sharedMailboxSignInBlocked | Should -BeFalse
        }
        It 'reports a hidden-contact check Unknown when the read fails, and Fail when the address is a mailbox' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { throw 'The remote server returned an error: (429).' }
            (Get-M365SecurityFact -Settings $script:FakeSettings -ContactAddress 'c.clients@msp.example').Facts.mspContactHidden | Should -BeNullOrEmpty
            Mock -ModuleName ExchangeHelpers Get-Recipient { [pscustomobject]@{ Name = 'Support'; RecipientTypeDetails = 'UserMailbox'; PrimarySmtpAddress = 'support@msp.example' } }
            (Get-M365SecurityFact -Settings $script:FakeSettings).Facts.supportContactHidden | Should -BeFalse
        }
    }

    Context 'Remediations plan and run through Invoke-M365Change' {
        BeforeEach {
            $global:SecWriteLog.Clear()
            Set-M365ChangeTarget -Service Exchange -Label 'test.onmicrosoft.com'
            Set-M365ChangeTarget -Service Graph -Label 'test.onmicrosoft.com'
        }
        It 'Set-M365SmtpAuth -Disabled $true plans one readable command and writes nothing under -WhatIf' {
            Mock -ModuleName SecurityHelpers Get-TransportConfig { [pscustomobject]@{ SmtpClientAuthenticationDisabled = $false } }
            Start-M365ChangeRecording
            $r = Set-M365SmtpAuth -Disabled $true -WhatIf
            $plan = Stop-M365ChangeRecording
            $plan.Text | Should -Be '[test.onmicrosoft.com] Set-TransportConfig -SmtpClientAuthenticationDisabled:$true'
            $plan.Action | Should -Be 'Turn SMTP AUTH OFF for the whole organization'
            $r.Changed | Should -BeFalse
            $r.WhatIf | Should -BeTrue
            $global:SecWriteLog.Count | Should -Be 0
        }
        It 'Set-M365SmtpAuth runs exactly the planned change' {
            Mock -ModuleName SecurityHelpers Get-TransportConfig { [pscustomobject]@{ SmtpClientAuthenticationDisabled = $false } }
            Start-M365ChangeRecording; $null = Set-M365SmtpAuth -Disabled $true -WhatIf; $plan = Stop-M365ChangeRecording
            Start-M365ChangeRecording -ApprovedPlan $plan
            $r = Set-M365SmtpAuth -Disabled $true 6>$null
            @((Stop-M365ChangeRecording).Status) | Should -Be @('Done')
            $r.State | Should -Be 'Off'
            $global:SecWriteLog[0].Params.SmtpClientAuthenticationDisabled | Should -BeTrue
        }
        It 'Set-M365ExternalSenderTag is idempotent' {
            Mock -ModuleName SecurityHelpers Get-ExternalInOutlook { [pscustomobject]@{ Enabled = $true } }
            (Set-M365ExternalSenderTag -Enabled $true).Changed | Should -BeFalse
            $global:SecWriteLog.Count | Should -Be 0
        }
        It 'Enable-M365AuditLogging plans both settings and reports nothing changed under -WhatIf' {
            Mock -ModuleName SecurityHelpers Get-AdminAuditLogConfig { [pscustomobject]@{ UnifiedAuditLogIngestionEnabled = $false } }
            Mock -ModuleName SecurityHelpers Get-OrganizationConfig { [pscustomobject]@{ AuditDisabled = $true } }
            Start-M365ChangeRecording
            $r = Enable-M365AuditLogging -WhatIf
            $plan = Stop-M365ChangeRecording
            @($plan.Command) | Should -Be @('Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled:$true', 'Set-OrganizationConfig -AuditDisabled:$false')
            @($r.Changed).Count | Should -Be 0
            $r.WhatIf | Should -BeTrue
        }
        It 'Set-M365AutoForwarding changes the default policy and warns about custom policies that allow forwarding' {
            Mock -ModuleName SecurityHelpers Get-HostedOutboundSpamFilterPolicy { [pscustomobject]@{ Name = 'Default'; Identity = 'Default'; IsDefault = $true; AutoForwardingMode = 'Automatic' }; [pscustomobject]@{ Name = 'Sales'; Identity = 'Sales'; IsDefault = $false; AutoForwardingMode = 'On' } }
            $r = Set-M365AutoForwarding -Mode Off -WarningVariable warned 6>$null 3>$null
            $r.Changed | Should -BeTrue
            $global:SecWriteLog[0].Params.Identity | Should -Be 'Default'
            ($warned -join ' ') | Should -Match 'Sales'
        }
        It 'Set-M365SecurityDefault goes to Graph and refuses to enable alongside CA' {
            Mock -ModuleName SecurityHelpers Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy { [pscustomobject]@{ IsEnabled = $false } }
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy { New-CaPolicy -Name 'x' }
            { Set-M365SecurityDefault -Enabled $true 6>$null } | Should -Throw '*Conditional Access*'
            Mock -ModuleName SecurityHelpers Get-MgIdentityConditionalAccessPolicy { }
            Start-M365ChangeRecording
            $null = Set-M365SecurityDefault -Enabled $true -WhatIf
            (Stop-M365ChangeRecording).Text | Should -Be '[test.onmicrosoft.com] Update-MgPolicyIdentitySecurityDefaultEnforcementPolicy -IsEnabled:$true'
            $global:SecWriteLog.Count | Should -Be 0
        }
    }
}
