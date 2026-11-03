#region Module setup ----------------------------------------------------------
#   WHAT   Strict mode; M365Helpers and ExchangeHelpers by path (DKIM status and the exact
#          recipient lookup are reused).
#   WHY    The audit is a list of small fact collectors plus one pure comparison, so a
#          new check is one collector entry and one baseline row. Every remediation goes
#          through M365Helpers' Invoke-M365Change.
Set-StrictMode -Version Latest
foreach ($dep in 'M365Helpers', 'ExchangeHelpers') {
    if (-not (Get-Module -Name $dep)) { Import-Module (Join-Path $PSScriptRoot '..' $dep "$dep.psd1") -ErrorAction Stop }
}
#endregion

#region Internal helpers --------------------------------------------------------
function Get-M365PolicyValue {
    # Internal. Walks a property path ('Conditions.Users.IncludeUsers') and returns $null
    # instead of throwing when a step is missing (Graph objects and test doubles differ).
    param($Object, [string]$Path)
    $o = $Object
    foreach ($name in $Path -split '\.') {
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) { $o = $o[$name]; continue }
        $p = $o.PSObject.Properties[$name]
        if (-not $p) { return $null }
        $o = $p.Value
    }
    return $o
}

function Test-M365True {
    # Internal. True only for a real $true or the string 'True' ([bool]'False' is $true in PowerShell).
    param($Value)
    return ("$Value" -eq 'True')
}
#endregion

#region Baseline file ------------------------------------------------------------
function Get-M365SecurityBaseline {
    <#
    .SYNOPSIS
        Loads the security baseline (config/baselines/security.local.json, else the example).
    .PARAMETER Path
        Explicit baseline file.
    .EXAMPLE
        (Get-M365SecurityBaseline).checks | Format-Table id, expected, severity
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path
    )
    if (-not $Path) {
        $dir = Join-Path $PSScriptRoot '..' '..' '..' '..' 'config' 'baselines'
        $Path = Join-Path $dir 'security.local.json'
        if (-not (Test-Path $Path)) { $Path = Join-Path $dir 'security.example.json' }
    }
    if (-not (Test-Path $Path)) { throw "Baseline not found: $Path" }
    $b = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($c in $b.checks) {
        foreach ($k in 'id', 'title', 'severity', 'remediation') { if (-not $c.$k) { throw "Baseline check is missing '$k' ($Path)." } }
        if (-not ($c.PSObject.Properties.Name -contains 'expected')) { throw "Baseline check '$($c.id)' has no 'expected' ($Path)." }
    }
    $b | Add-Member -NotePropertyName Path -NotePropertyValue $Path -Force
    return $b
}
#endregion

#region Fact collection (read-only) -------------------------------------------
function Get-M365SecurityFact {
    <#
    .SYNOPSIS
        Collects the tenant facts the baseline checks compare against. Read-only.
    .DESCRIPTION
        Needs a Graph session in the client tenant and an Exchange Online session for it.
        Each collector runs in its own try/catch; a failed collector yields $null plus an
        error string so one missing permission never hides the other results.

        A fact that depends on a read that failed is $null (Unknown), never a Pass or Fail:
        when Conditional Access cannot be read, mfaEnforced, legacyAuthBlocked and
        breakGlassExcludedFromCA are Unknown (unless Security Defaults alone settles MFA and
        legacy auth). Conditional Access counts for mfaEnforced only when an enabled policy
        includes All users, All cloud apps and every client app type, and requires MFA (or
        an authentication strength); for legacyAuthBlocked only when an enabled policy
        includes All users and All cloud apps, targets Exchange ActiveSync and other
        clients, and blocks. autoForwardingBlocked needs the default outbound spam policy
        set to Off AND no enabled custom outbound spam policy allowing it (On).

        Graph scopes: Policy.Read.All, Directory.Read.All, Domain.Read.All, User.Read.All,
        RoleManagement.Read.Directory. Exchange: View-Only Organization Management or better.
    .PARAMETER BreakGlassUpnPrefix
        Local part of the break-glass UPN to look for. Default from settings, else 'breakglass'.
    .PARAMETER Settings
        MSP settings (support address, admin account prefixes, list names). Loaded if omitted.
    .PARAMETER ContactAddress
        The client's alias on our clients@ mailbox (<name>.clients@...), for the MSP contact
        and IT@ list checks. From the client config's internalAlias. Omit to skip those checks.
    .PARAMETER PrimaryDomain
        The client's mail domain, for the IT@ and MSPalerts@ list checks. Omit to skip.
    .PARAMETER OnmicrosoftDomain
        The client's initial <name>.onmicrosoft.com domain, where break-glass and mspadmin
        live. Pass the one the Exchange session verified (Assert-M365Exchange .InitialDomain),
        never a custom domain. Looked up in Graph (the IsInitial domain) if omitted.
    .PARAMETER SkipExchange
        Only Graph-based facts (no Exchange session needed).
    .EXAMPLE
        $facts = Get-M365SecurityFact -ContactAddress contoso.clients@msp.example -PrimaryDomain contosodental.example
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$BreakGlassUpnPrefix,

        [Parameter()]
        [object]$Settings,

        [Parameter()]
        [string]$ContactAddress,

        [Parameter()]
        [string]$PrimaryDomain,

        [Parameter()]
        [string]$OnmicrosoftDomain,

        [Parameter()]
        [switch]$SkipExchange
    )
    if (-not $Settings) { $Settings = try { Get-M365Settings } catch { $null } }
    if (-not $BreakGlassUpnPrefix) { $BreakGlassUpnPrefix = if ($Settings -and (Get-M365PolicyValue $Settings 'breakGlass.upnPrefix')) { $Settings.breakGlass.upnPrefix } else { 'breakglass' } }
    $supportEmail = if ($Settings -and "$(Get-M365PolicyValue $Settings 'msp.supportEmail')" -and $Settings.msp.supportEmail -notmatch '^<') { $Settings.msp.supportEmail } else { $null }
    $adminPrefixes = @(if ($Settings -and (Get-M365PolicyValue $Settings 'adminAccounts')) { $Settings.adminAccounts | ForEach-Object { $_.upnPrefix } } else { 'mspadmin' })
    $itName = if ($Settings -and (Get-M365PolicyValue $Settings 'distributionLists.it')) { $Settings.distributionLists.it } else { 'IT' }
    $alertsName = if ($Settings -and (Get-M365PolicyValue $Settings 'distributionLists.alerts')) { $Settings.distributionLists.alerts } else { 'MSPalerts' }
    $facts = @{}
    $errors = @{}
    #   GOTCHA "& { @() }" returns $null, so an empty list and a failed read look the same.
    #          Lists go through $collectList (always an array), and every derived fact asks
    #          $errors whether its source was READ, never whether the value is $null.
    $collect = {
        param([string]$Id, [scriptblock]$Body)
        try { $facts[$Id] = & $Body } catch { $facts[$Id] = $null; $errors[$Id] = $_.Exception.Message }
    }
    $collectList = {
        param([string]$Id, [scriptblock]$Body)
        try { $facts[$Id] = @(& $Body) } catch { $facts[$Id] = $null; $errors[$Id] = $_.Exception.Message }
    }
    $unknown = {
        param([string]$Id, [string[]]$Because)
        $facts[$Id] = $null
        $why = @($Because | Where-Object { $errors.ContainsKey($_) } | ForEach-Object { "$_ could not be read: $($errors[$_])" })
        if ($why.Count -gt 0) { $errors[$Id] = $why -join ' ' }
    }

    #region Graph: Security Defaults and Conditional Access -----------------------------
    & $collect 'securityDefaults' { Test-M365True (Get-M365PolicyValue (Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy -ErrorAction Stop) 'IsEnabled') }
    & $collectList 'caPoliciesRaw' { Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop }
    $caRead = -not $errors.ContainsKey('caPoliciesRaw')
    if ($caRead) {
        $facts['caPolicies'] = @($facts['caPoliciesRaw'] | Where-Object { $_ } | ForEach-Object {
                $clients = @(Get-M365PolicyValue $_ 'Conditions.ClientAppTypes' | Where-Object { $_ } | ForEach-Object { "$_" })
                $controls = @(Get-M365PolicyValue $_ 'GrantControls.BuiltInControls' | ForEach-Object { "$_" })
                [pscustomobject]@{
                    Name          = "$(Get-M365PolicyValue $_ 'DisplayName')"
                    State         = "$(Get-M365PolicyValue $_ 'State')"
                    AllUsers      = @(Get-M365PolicyValue $_ 'Conditions.Users.IncludeUsers') -contains 'All'
                    AllApps       = @(Get-M365PolicyValue $_ 'Conditions.Applications.IncludeApplications') -contains 'All'
                    #   GOTCHA No client app condition, 'all', or both modern client types
                    #          (browser + mobile/desktop) count as every client.
                    AllClientApps = ($clients.Count -eq 0 -or $clients -contains 'all' -or ($clients -contains 'browser' -and $clients -contains 'mobileAppsAndDesktopClients'))
                    #   GOTCHA The Graph SDK returns an empty AuthenticationStrength object when
                    #          none is set, so only a strength with an Id counts.
                    RequiresMfa   = ($controls -contains 'mfa') -or [bool]"$(Get-M365PolicyValue $_ 'GrantControls.AuthenticationStrength.Id')"
                    Blocks        = ($controls -contains 'block')
                    LegacyClients = ($clients -contains 'exchangeActiveSync' -and $clients -contains 'other')
                }
            })
        $enabledCa = @($facts['caPolicies'] | Where-Object { $_.State -eq 'enabled' })
        $facts['caRequiresMfaAllUsers'] = @($enabledCa | Where-Object { $_.AllUsers -and $_.AllApps -and $_.AllClientApps -and $_.RequiresMfa }).Count -gt 0
        $facts['caBlocksLegacyAuth'] = @($enabledCa | Where-Object { $_.AllUsers -and $_.AllApps -and $_.LegacyClients -and $_.Blocks }).Count -gt 0
    } else {
        $facts['caPolicies'] = $null; $facts['caRequiresMfaAllUsers'] = $null; $facts['caBlocksLegacyAuth'] = $null
    }
    #   WHAT   Security Defaults on settles it; otherwise CA decides; any unread source is Unknown.
    foreach ($pair in @(@('mfaEnforced', 'caRequiresMfaAllUsers'), @('legacyAuthBlocked', 'caBlocksLegacyAuth'))) {
        $sd = $facts['securityDefaults']; $ca = $facts[$pair[1]]
        if ($sd -eq $true -or $ca -eq $true) { $facts[$pair[0]] = $true }
        elseif ($null -eq $sd -or $null -eq $ca) { & $unknown $pair[0] @('securityDefaults', 'caPoliciesRaw') }
        else { $facts[$pair[0]] = $false }
    }
    #endregion

    #region Graph: directory settings ---------------------------------------------------------
    & $collect 'passwordNeverExpires' {
        $domains = @(Get-MgDomain -All -ErrorAction Stop | Where-Object { Test-M365True (Get-M365PolicyValue $_ 'IsVerified') })
        -not ($domains | Where-Object { $v = Get-M365PolicyValue $_ 'PasswordValidityPeriodInDays'; $v -and $v -lt 2147483647 })
    }
    & $collect 'authorizationPolicy' { Get-MgPolicyAuthorizationPolicy -ErrorAction Stop | Select-Object -First 1 }
    $ap = $facts['authorizationPolicy']
    $facts['ssprEnabled'] = if ($ap) { Test-M365True (Get-M365PolicyValue $ap 'AllowedToUseSspr') } else { $null }
    $facts['userConsentBlocked'] = if ($ap) { @(Get-M365PolicyValue $ap 'DefaultUserRolePermissions.PermissionGrantPoliciesAssigned' | Where-Object { $_ }).Count -eq 0 } else { $null }
    $facts['guestInviteRestricted'] = if ($ap) { "$(Get-M365PolicyValue $ap 'AllowInvitesFrom')" -in 'adminsAndGuestInviters', 'none' } else { $null }
    & $collectList 'globalAdmins' {
        $ga = Get-MgDirectoryRole -Filter "displayName eq 'Global Administrator'" -ErrorAction Stop | Select-Object -First 1
        if ($ga) { Get-MgDirectoryRoleMember -DirectoryRoleId $ga.Id -All -ErrorAction Stop | ForEach-Object { $_.AdditionalProperties['userPrincipalName'] } }
    }
    $facts['globalAdminCount'] = if ($errors.ContainsKey('globalAdmins')) { $null } else { @($facts['globalAdmins']).Count }
    #endregion

    #region Graph: break-glass ------------------------------------------------------------
    #   GOTCHA The break-glass account lives on the tenant's INITIAL domain
    #          (<name>.onmicrosoft.com). A custom domain passed by mistake would find nothing
    #          and report a false Fail, so the initial domain comes from the verified
    #          Exchange session or from Graph (IsInitial), and only as a last resort is any
    #          UPN that starts with the prefix accepted.
    $bgDomain = $OnmicrosoftDomain
    if (-not $bgDomain) {
        & $collect 'initialDomain' { @(Get-MgDomain -All -ErrorAction Stop | Where-Object { Test-M365True (Get-M365PolicyValue $_ 'IsInitial') } | ForEach-Object { "$(Get-M365PolicyValue $_ 'Id')" }) | Select-Object -First 1 }
        $bgDomain = $facts['initialDomain']
    }
    $bgFilter = if ($bgDomain) { "userPrincipalName eq '$BreakGlassUpnPrefix@$bgDomain'" } else { "startswith(userPrincipalName,'$BreakGlassUpnPrefix@')" }
    & $collect 'breakGlassUser' { Get-MgUser -Filter $bgFilter -Property id, userPrincipalName -ErrorAction Stop | Select-Object -First 1 }
    $bg = $facts['breakGlassUser']
    if ($errors.ContainsKey('breakGlassUser')) {
        foreach ($id in 'breakGlassExists', 'breakGlassIsGlobalAdmin', 'breakGlassExcludedFromCA') { & $unknown $id @('breakGlassUser') }
    } elseif (-not $bg) {
        $facts['breakGlassExists'] = $false; $facts['breakGlassIsGlobalAdmin'] = $false; $facts['breakGlassExcludedFromCA'] = $false
    } else {
        $facts['breakGlassExists'] = $true
        if ($errors.ContainsKey('globalAdmins')) { & $unknown 'breakGlassIsGlobalAdmin' @('globalAdmins') }
        else { $facts['breakGlassIsGlobalAdmin'] = @($facts['globalAdmins']) -contains $bg.UserPrincipalName }
        if (-not $caRead) {
            & $unknown 'breakGlassExcludedFromCA' @('caPoliciesRaw')
        } else {
            $enabledPolicies = @($facts['caPoliciesRaw'] | Where-Object { $_ -and "$(Get-M365PolicyValue $_ 'State')" -eq 'enabled' })
            $facts['breakGlassNotExcludedFrom'] = @($enabledPolicies | Where-Object { @(Get-M365PolicyValue $_ 'Conditions.Users.ExcludeUsers') -notcontains $bg.Id } | ForEach-Object { "$(Get-M365PolicyValue $_ 'DisplayName')" })
            $facts['breakGlassExcludedFromCA'] = (@($facts['breakGlassNotExcludedFrom']).Count -eq 0)
            if (-not $facts['breakGlassExcludedFromCA']) { $facts['breakGlassExcludedFromCADetail'] = "not excluded from: $($facts['breakGlassNotExcludedFrom'] -join ', ')" }
        }
    }
    & $collect 'mspAdminExists' {
        $found = foreach ($prefix in $adminPrefixes) { Get-MgUser -Filter "startswith(userPrincipalName,'$prefix@')" -Property id -ErrorAction Stop | Select-Object -First 1 }
        [bool](@($found | Where-Object { $_ }).Count -gt 0)
    }
    if ($supportEmail) {
        & $collect 'technicalContactSet' { @((Get-MgOrganization -ErrorAction Stop | Select-Object -First 1).TechnicalNotificationMails) -contains $supportEmail }
    }
    #endregion

    #region Exchange Online ----------------------------------------------------------
    if (-not $SkipExchange) {
        & $collect 'unifiedAuditLog' { Test-M365True (Get-AdminAuditLogConfig -ErrorAction Stop).UnifiedAuditLogIngestionEnabled }
        & $collect 'organizationConfig' { Get-OrganizationConfig -ErrorAction Stop }
        $oc = $facts['organizationConfig']
        $facts['mailboxAuditing'] = if ($oc) { -not (Test-M365True $oc.AuditDisabled) } else { $null }
        $facts['modernAuth'] = if ($oc) { Test-M365True $oc.OAuth2ClientProfileEnabled } else { $null }

        #   WHAT   The default policy must be Off, and no ENABLED custom policy (one with an
        #          enabled rule) may allow it. A custom policy overrides the default for the
        #          users its rule covers, so checking only the default was a false Pass.
        & $collect 'autoForwarding' {
            $policies = @(Get-HostedOutboundSpamFilterPolicy -ErrorAction Stop)
            $rules = @(Get-HostedOutboundSpamFilterRule -ErrorAction Stop)
            $default = $policies | Where-Object { Test-M365True (Get-M365PolicyValue $_ 'IsDefault') } | Select-Object -First 1
            if (-not $default) { $default = Get-HostedOutboundSpamFilterPolicy -Identity Default -ErrorAction Stop }
            $enabledNames = @($rules | Where-Object { "$(Get-M365PolicyValue $_ 'State')" -eq 'Enabled' } | ForEach-Object { "$(Get-M365PolicyValue $_ 'HostedOutboundSpamFilterPolicy')" })
            $allowing = @($policies | Where-Object { -not (Test-M365True (Get-M365PolicyValue $_ 'IsDefault')) -and "$($_.Name)" -in $enabledNames -and "$($_.AutoForwardingMode)" -eq 'On' } | ForEach-Object { "$($_.Name)" })
            [pscustomobject]@{ DefaultMode = "$($default.AutoForwardingMode)"; CustomAllowing = $allowing }
        }
        $af = $facts['autoForwarding']
        if ($af) {
            $facts['autoForwardingBlocked'] = ($af.DefaultMode -eq 'Off') -and @($af.CustomAllowing).Count -eq 0
            $allowedBy = [System.Collections.Generic.List[string]]::new()
            if ($af.DefaultMode -ne 'Off') { $allowedBy.Add("Default ($($af.DefaultMode))") }
            foreach ($name in @($af.CustomAllowing)) { if ($name) { $allowedBy.Add("$name (On)") } }
            $facts['autoForwardingAllowedBy'] = @($allowedBy)
            if (-not $facts['autoForwardingBlocked']) { $facts['autoForwardingBlockedDetail'] = "not Off in: $($facts['autoForwardingAllowedBy'] -join ', ')" }
        } else { & $unknown 'autoForwardingBlocked' @('autoForwarding') }

        & $collect 'externalSenderTag' { Test-M365True (Get-ExternalInOutlook -ErrorAction Stop | Select-Object -First 1).Enabled }
        & $collect 'smtpAuthDisabled' { Test-M365True (Get-TransportConfig -ErrorAction Stop).SmtpClientAuthenticationDisabled }
        & $collect 'spoofIntelligence' {
            $p = Get-AntiPhishPolicy -ErrorAction Stop | Where-Object { Test-M365True (Get-M365PolicyValue $_ 'IsDefault') } | Select-Object -First 1
            if (-not $p) { $p = Get-AntiPhishPolicy -ErrorAction Stop | Select-Object -First 1 }
            Test-M365True $p.EnableSpoofIntelligence
        }
        & $collectList 'dkimDomains' {
            foreach ($d in @(Get-AcceptedDomain -ErrorAction Stop | Where-Object { $_.DomainName -notlike '*.onmicrosoft.com' })) {
                $st = Get-M365DkimStatus -Domain $d.DomainName
                if ($st.Status -eq 'Unknown') { throw $st.Error }
                [pscustomobject]@{ Domain = $d.DomainName; Enabled = $st.Enabled; Published = ($st.Selector1Published -and $st.Selector2Published) }
            }
        }
        if ($errors.ContainsKey('dkimDomains')) { & $unknown 'dkimAllDomains' @('dkimDomains') }
        else { $facts['dkimAllDomains'] = @($facts['dkimDomains'] | Where-Object { -not $_.Enabled }).Count -eq 0 }

        #   GOTCHA Every shared mailbox's account must be READ; one that cannot be read makes
        #          the fact Unknown instead of quietly counting as "sign-in blocked".
        & $collectList 'sharedMailboxesSignInEnabled' {
            $unread = [System.Collections.Generic.List[string]]::new()
            $enabled = foreach ($mb in @(Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited -ErrorAction Stop)) {
                $objectId = "$(Get-M365PolicyValue $mb 'ExternalDirectoryObjectId')"
                if (-not $objectId) { $unread.Add("$($mb.PrimarySmtpAddress) (no directory object id)"); continue }
                try { $u = Get-MgUser -UserId $objectId -Property accountEnabled, userPrincipalName -ErrorAction Stop }
                catch { $unread.Add("$($mb.PrimarySmtpAddress) ($($_.Exception.Message))"); continue }
                if (Test-M365True (Get-M365PolicyValue $u 'AccountEnabled')) { "$(Get-M365PolicyValue $u 'UserPrincipalName')" }
            }
            if ($unread.Count -gt 0) { throw "Could not read the account of $($unread.Count) shared mailbox(es): $($unread -join '; ')" }
            $enabled
        }
        if ($errors.ContainsKey('sharedMailboxesSignInEnabled')) { & $unknown 'sharedMailboxSignInBlocked' @('sharedMailboxesSignInEnabled') }
        else {
            $facts['sharedMailboxSignInBlocked'] = @($facts['sharedMailboxesSignInEnabled']).Count -eq 0
            if (-not $facts['sharedMailboxSignInBlocked']) { $facts['sharedMailboxSignInBlockedDetail'] = "sign-in enabled: $($facts['sharedMailboxesSignInEnabled'] -join ', ')" }
        }

        #   WHAT   MSP standard objects our onboarding creates in every tenant.
        #   WHY    "Is this client set up our way" is the question techs actually ask.
        #   GOTCHA Exact lookups (Get-M365ExactRecipient): "not found" is a Fail, a failed
        #          read is Unknown, and the object must be the right kind with the right
        #          PRIMARY address (an alias on something else does not count).
        $typeOf = { param($r) $t = "$(Get-M365PolicyValue $r 'RecipientTypeDetails')"; if (-not $t) { $t = "$(Get-M365PolicyValue $r 'RecipientType')" }; $t }
        $hiddenContact = {
            param([string]$Address)
            $r = Get-M365ExactRecipient -Kind Recipient -Identity $Address
            if (-not $r -or (& $typeOf $r) -ne 'MailContact') { return $false }
            $c = Get-M365ExactRecipient -Kind MailContact -Identity "$($r.PrimarySmtpAddress)"
            [bool]$c -and (Test-M365True (Get-M365PolicyValue $c 'HiddenFromAddressListsEnabled'))
        }
        $listWithMember = {
            param([string]$Address, [string]$Member)
            $g = Get-M365ExactRecipient -Kind Recipient -Identity $Address
            if (-not $g -or (& $typeOf $g) -ne 'MailUniversalDistributionGroup' -or "$($g.PrimarySmtpAddress)" -ne $Address) { return $false }
            $rec = Get-M365ExactRecipient -Kind Recipient -Identity $Member
            if (-not $rec) { return $false }
            $members = @(Get-DistributionGroupMember -Identity "$($g.PrimarySmtpAddress)" -ResultSize Unlimited -ErrorAction Stop)
            @($members | Where-Object { "$(Get-M365PolicyValue $_ 'PrimarySmtpAddress')" -eq "$($rec.PrimarySmtpAddress)" }).Count -gt 0
        }
        if ($ContactAddress) { & $collect 'mspContactHidden' { & $hiddenContact $ContactAddress } }
        if ($supportEmail) { & $collect 'supportContactHidden' { & $hiddenContact $supportEmail } }
        if ($PrimaryDomain -and $ContactAddress) { & $collect 'itListConfigured' { & $listWithMember "$itName@$PrimaryDomain" $ContactAddress } }
        if ($PrimaryDomain -and $supportEmail) { & $collect 'alertsListConfigured' { & $listWithMember "$alertsName@$PrimaryDomain" $supportEmail } }
    }
    #endregion

    [pscustomobject]@{ Facts = $facts; Errors = $errors; CollectedAt = (Get-Date).ToUniversalTime() }
}
#endregion

#region Comparison (pure) ----------------------------------------------------------
function Compare-M365SecurityBaseline {
    <#
    .SYNOPSIS
        Compares collected facts to the baseline. Pure; returns one row per check.
    .DESCRIPTION
        expected may be a boolean, string, number, or an object with min/max. Result is Pass,
        Fail, or Unknown (fact missing or collector failed). Each row carries the severity,
        the remediation text from the baseline, and the actual value, so the table is the
        report and the to-do list at once. A fact named '<id>Detail' (for example which
        policies still allow forwarding) is appended to Actual.
    .PARAMETER Facts
        Hashtable from Get-M365SecurityFact (.Facts), or any hashtable keyed by check id.
    .PARAMETER Baseline
        From Get-M365SecurityBaseline.
    .PARAMETER Errors
        Collector errors (.Errors) to annotate Unknown rows.
    .EXAMPLE
        Compare-M365SecurityBaseline -Facts $r.Facts -Baseline (Get-M365SecurityBaseline) -Errors $r.Errors | Format-Table Result, Severity, Title, Actual
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Facts,

        [Parameter(Mandatory)]
        [object]$Baseline,

        [Parameter()]
        [hashtable]$Errors = @{}
    )
    $order = @{ High = 0; Medium = 1; Low = 2 }
    $rows = foreach ($check in $Baseline.checks) {
        $has = $Facts.ContainsKey($check.id) -and $null -ne $Facts[$check.id]
        $actual = if ($has) { $Facts[$check.id] } else { $null }
        $expected = $check.expected
        $pass = $null
        if ($has) {
            if ($expected -is [pscustomobject] -and ($expected.PSObject.Properties.Name -contains 'min' -or $expected.PSObject.Properties.Name -contains 'max')) {
                $n = [double]$actual
                $pass = (-not ($expected.PSObject.Properties.Name -contains 'min') -or $n -ge $expected.min) -and (-not ($expected.PSObject.Properties.Name -contains 'max') -or $n -le $expected.max)
            } elseif ($expected -is [bool]) {
                $pass = ([bool]$actual -eq $expected)
            } else {
                $pass = ("$actual" -eq "$expected")
            }
        }
        $detailKey = "$($check.id)Detail"
        $detail = if ($has -and $Facts.ContainsKey($detailKey) -and $Facts[$detailKey]) { " ($(@($Facts[$detailKey]) -join '; '))" } else { '' }
        [pscustomobject]@{
            Id          = $check.id
            Title       = $check.title
            Severity    = $check.severity
            Result      = if ($null -eq $pass) { 'Unknown' } elseif ($pass) { 'Pass' } else { 'Fail' }
            Expected    = if ($expected -is [pscustomobject]) { ($expected.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ' } else { "$expected" }
            Actual      = if ($has) { if ($actual -is [array]) { ($actual -join '; ') + $detail } else { "$actual$detail" } } elseif ($Errors.ContainsKey($check.id)) { "error: $($Errors[$check.id])" } else { 'not collected' }
            Remediation = $check.remediation
        }
    }
    return @($rows | Sort-Object { if ($_.Result -eq 'Fail') { 0 } elseif ($_.Result -eq 'Unknown') { 1 } else { 2 } }, { $order[$_.Severity] }, Title)
}
#endregion

#region Remediations (idempotent, every change through Invoke-M365Change) ------------
function Enable-M365AuditLogging {
    <#
    .SYNOPSIS
        Turns on unified audit log ingestion and default mailbox auditing if they are off.
    .DESCRIPTION
        Two organization-wide Exchange settings, each changed only when it is off, each
        through Invoke-M365Change. Changed lists what actually ran.
    .EXAMPLE
        Enable-M365AuditLogging -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param()
    $cfg = Get-AdminAuditLogConfig -ErrorAction Stop
    $org = Get-OrganizationConfig -ErrorAction Stop
    $ualOn = Test-M365True $cfg.UnifiedAuditLogIngestionEnabled
    $mailboxAuditOn = -not (Test-M365True $org.AuditDisabled)
    $changed = @(); $dry = $false
    if (-not $ualOn) {
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action 'Turn on unified audit log ingestion for the organization' `
            -Command 'Set-AdminAuditLogConfig' -Parameters ([ordered]@{ UnifiedAuditLogIngestionEnabled = $true })
        if ($run.Ran) { $changed += 'UnifiedAuditLog' } else { $dry = $true }
    }
    if (-not $mailboxAuditOn) {
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action 'Turn on default mailbox auditing for the organization' `
            -Command 'Set-OrganizationConfig' -Parameters ([ordered]@{ AuditDisabled = $false })
        if ($run.Ran) { $changed += 'MailboxAuditing' } else { $dry = $true }
    }
    [pscustomobject]@{ UnifiedAuditLogWasEnabled = $ualOn; MailboxAuditingWasEnabled = $mailboxAuditOn; Changed = $changed; WhatIf = $dry }
}

function Set-M365AutoForwarding {
    <#
    .SYNOPSIS
        Sets the default outbound spam policy's automatic forwarding mode (Off blocks external auto-forward).
    .DESCRIPTION
        Changes only the default policy. Custom outbound spam policies override it for the
        users their rule covers; any that still allow forwarding (On) are listed in a warning
        so they can be fixed by hand.
    .PARAMETER Mode
        Off, On, or Automatic (Microsoft-controlled; currently behaves as Off).
    .EXAMPLE
        Set-M365AutoForwarding -Mode Off -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Off', 'On', 'Automatic')]
        [string]$Mode
    )
    $policies = @(Get-HostedOutboundSpamFilterPolicy -ErrorAction Stop)
    $policy = $policies | Where-Object { Test-M365True (Get-M365PolicyValue $_ 'IsDefault') } | Select-Object -First 1
    if (-not $policy) { $policy = Get-HostedOutboundSpamFilterPolicy -Identity Default -ErrorAction Stop }
    $custom = @($policies | Where-Object { -not (Test-M365True (Get-M365PolicyValue $_ 'IsDefault')) -and "$($_.AutoForwardingMode)" -eq 'On' } | ForEach-Object { "$($_.Name)" })
    if ($Mode -ne 'On' -and $custom.Count -gt 0) {
        Write-Warning "Custom outbound spam policies still allow automatic external forwarding for the users they cover: $($custom -join ', '). Review and change them by hand (Set-HostedOutboundSpamFilterPolicy -Identity <name> -AutoForwardingMode Off)."
    }
    $current = "$($policy.AutoForwardingMode)"
    if ($current -eq $Mode) { return [pscustomobject]@{ Policy = $policy.Name; Mode = $current; Changed = $false; WhatIf = $false } }
    $policyId = if ("$(Get-M365PolicyValue $policy 'Identity')") { "$($policy.Identity)" } else { "$($policy.Name)" }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Set automatic external forwarding to $Mode on outbound spam policy '$($policy.Name)' (was $current)" `
        -Command 'Set-HostedOutboundSpamFilterPolicy' -Parameters ([ordered]@{ Identity = $policyId; AutoForwardingMode = $Mode })
    [pscustomobject]@{ Policy = $policy.Name; Mode = $(if ($run.Ran) { $Mode } else { $current }); Changed = $run.Ran; Was = $current; WhatIf = (-not $run.Ran) }
}

function Set-M365SecurityDefault {
    <#
    .SYNOPSIS
        Enables or disables Security Defaults. Refuses to enable while Conditional Access policies exist.
    .DESCRIPTION
        Microsoft blocks enabling Security Defaults in a tenant with Conditional Access
        policies; this checks first so the error is understandable. Disabling is allowed only
        with -Force, because a tenant without Security Defaults and without CA has no MFA.
        The change goes through Invoke-M365Change (Service Graph).
    .PARAMETER Enabled
        Desired state.
    .PARAMETER Force
        Allow disabling.
    .EXAMPLE
        Set-M365SecurityDefault -Enabled $true -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [bool]$Enabled,

        [Parameter()]
        [switch]$Force
    )
    $policy = Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy -ErrorAction Stop
    $current = Test-M365True (Get-M365PolicyValue $policy 'IsEnabled')
    $state = if ($Enabled) { 'On' } else { 'Off' }
    if ($current -eq $Enabled) { return [pscustomobject]@{ Enabled = $Enabled; State = $state; Changed = $false; WhatIf = $false } }
    if ($Enabled) {
        $ca = @(Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop)
        if ($ca.Count -gt 0) { throw "Tenant has $($ca.Count) Conditional Access polic$(if ($ca.Count -eq 1) { 'y' } else { 'ies' }). Security Defaults cannot be enabled alongside CA; use CA for MFA and legacy auth instead." }
    } elseif (-not $Force) {
        throw 'Disabling Security Defaults removes MFA enforcement unless Conditional Access covers it. Pass -Force if CA policies are in place.'
    }
    $what = if ($Enabled) { 'Turn ON Security Defaults (MFA registration and prompts for everyone, legacy authentication blocked)' } else { 'Turn OFF Security Defaults (MFA and the legacy-auth block then depend on Conditional Access)' }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action $what `
        -Command 'Update-MgPolicyIdentitySecurityDefaultEnforcementPolicy' -Parameters ([ordered]@{ IsEnabled = [bool]$Enabled })
    if ($run.Ran) { return [pscustomobject]@{ Enabled = $Enabled; State = $state; Changed = $true; WhatIf = $false } }
    [pscustomobject]@{ Enabled = $current; State = $(if ($current) { 'On' } else { 'Off' }); Changed = $false; WhatIf = $true }
}

function Set-M365ExternalSenderTag {
    <#
    .SYNOPSIS
        Enables or disables the "External" sender tag in Outlook.
    .DESCRIPTION
        Organization-wide Exchange setting, changed only when it differs, through Invoke-M365Change.
    .PARAMETER Enabled
        Desired state.
    .EXAMPLE
        Set-M365ExternalSenderTag -Enabled $true -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [bool]$Enabled
    )
    $current = Test-M365True (Get-ExternalInOutlook -ErrorAction Stop | Select-Object -First 1).Enabled
    $state = if ($Enabled) { 'On' } else { 'Off' }
    if ($current -eq $Enabled) { return [pscustomobject]@{ Enabled = $Enabled; State = $state; Changed = $false; WhatIf = $false } }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Turn $(if ($Enabled) { 'ON' } else { 'OFF' }) the External sender tag in Outlook for the organization" `
        -Command 'Set-ExternalInOutlook' -Parameters ([ordered]@{ Enabled = [bool]$Enabled })
    if ($run.Ran) { return [pscustomobject]@{ Enabled = $Enabled; State = $state; Changed = $true; WhatIf = $false } }
    [pscustomobject]@{ Enabled = $current; State = $(if ($current) { 'On' } else { 'Off' }); Changed = $false; WhatIf = $true }
}

function Set-M365SmtpAuth {
    <#
    .SYNOPSIS
        Disables (or re-enables) SMTP AUTH organization-wide. Per-mailbox exceptions stay possible.
    .DESCRIPTION
        Sets Set-TransportConfig -SmtpClientAuthenticationDisabled, only when it differs, through
        Invoke-M365Change. -Disabled $true means SMTP AUTH is OFF (the State in the output is
        'Off'). Devices that must relay (printers, scanners) get a per-mailbox exception by
        hand: Set-CASMailbox -Identity <mailbox> -SmtpClientAuthenticationDisabled $false.
    .PARAMETER Disabled
        $true turns SMTP AUTH off for the organization; $false turns it back on.
    .EXAMPLE
        Set-M365SmtpAuth -Disabled $true -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [bool]$Disabled
    )
    $current = Test-M365True (Get-TransportConfig -ErrorAction Stop).SmtpClientAuthenticationDisabled
    $state = if ($Disabled) { 'Off' } else { 'On' }
    if ($current -eq $Disabled) { return [pscustomobject]@{ Disabled = $Disabled; State = $state; Changed = $false; WhatIf = $false } }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Turn SMTP AUTH $(if ($Disabled) { 'OFF' } else { 'ON' }) for the whole organization" `
        -Command 'Set-TransportConfig' -Parameters ([ordered]@{ SmtpClientAuthenticationDisabled = [bool]$Disabled })
    if ($run.Ran) { return [pscustomobject]@{ Disabled = $Disabled; State = $state; Changed = $true; WhatIf = $false } }
    [pscustomobject]@{ Disabled = $current; State = $(if ($current) { 'Off' } else { 'On' }); Changed = $false; WhatIf = $true }
}
#endregion

Export-ModuleMember -Function Get-M365SecurityBaseline, Get-M365SecurityFact, Compare-M365SecurityBaseline,
    Enable-M365AuditLogging, Set-M365AutoForwarding, Set-M365SecurityDefault, Set-M365ExternalSenderTag, Set-M365SmtpAuth
