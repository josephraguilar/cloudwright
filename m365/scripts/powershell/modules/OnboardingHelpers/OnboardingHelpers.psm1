#region Module setup ----------------------------------------------------------
#   WHAT   Strict mode. This module has no Graph or Exchange calls of its own.
#   WHY    The plan must be computable offline so -WhatIf and the tests can show
#          exactly what a run would do before anyone signs in anywhere.
Set-StrictMode -Version Latest
#   GOTCHA The repo is not on PSModulePath, so M365Helpers cannot be a manifest
#          RequiredModule (Test-ModuleManifest would fail). Load it by path instead.
if (-not (Get-Module -Name M365Helpers)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Helpers' 'M365Helpers.psd1') -ErrorAction Stop
}
#endregion

function Get-OnboardingPlan {
    <#
    .SYNOPSIS
        Builds the ordered list of onboarding steps for one client from its config.
    .DESCRIPTION
        Mirrors the Autotask onboarding checklist, sections 1 and 5 (the two that happen
        inside Microsoft 365). Each step says:

          Id      checklist number, e.g. 5.11
          Phase   Internal (our tenant) or Tenant (client tenant)
          Kind    Auto    = a script does it end to end
                  Assisted= a script does the API part, a person does the rest (DNS, forms)
                  Manual  = no API; printed as a reminder with the SOP link
          Applies whether this client needs it (ironScales, Hudu id present, ...)
          Script  repo-relative path of the task script that runs it
          Invocations one hashtable of parameters per run of that script (several when a step fans out per POC, domain or account)

        The orchestrator runs this list. Test-ClientOnboarding checks it. Nothing else
        decides step order, so changing the process means changing this one function.
    .PARAMETER Client
        Client config from Get-M365ClientConfig.
    .PARAMETER Settings
        MSP settings from Get-M365Settings.
    .PARAMETER Phase
        Return only steps in these phases. Default all.
    .EXAMPLE
        Get-OnboardingPlan -Client $client -Settings $settings | Format-Table Id, Phase, Kind, Applies, Name
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Client,

        [Parameter(Mandatory)]
        [object]$Settings,

        [Parameter()]
        [ValidateSet('Internal', 'Tenant')]
        [string[]]$Phase = @('Internal', 'Tenant')
    )

    #region 1. Shorthands -------------------------------------------------------
    $msp = $Settings.msp
    $domain = $Client.primaryDomain
    $sop1 = ''
    $sop5 = ''
    if ($Settings.PSObject.Properties.Name -contains 'onboarding' -and $Settings.onboarding) {
        if ($Settings.onboarding.PSObject.Properties.Name -contains 'internalSopUrl') {
            $sop1 = [string]$Settings.onboarding.internalSopUrl
        }
        if ($Settings.onboarding.PSObject.Properties.Name -contains 'tenantSopUrl') {
            $sop5 = [string]$Settings.onboarding.tenantSopUrl
        }
    }
    $hasHudu = [int]$Client.huduCompanyId -gt 0
    $dl = $Settings.distributionLists
    $itName = if ($dl -and $dl.it) { $dl.it } else { 'IT' }
    $alertsName = if ($dl -and $dl.alerts) { $dl.alerts } else { 'MSPalerts' }
    $reportMailbox = if ($Settings.ironScalesReportMailbox) { $Settings.ironScalesReportMailbox } else { '911' }
    $bg = $Settings.breakGlass
    $pocEmails = @($Client.poc | Where-Object { $_.email } | ForEach-Object { $_.email })
    #   GOTCHA Every Exchange step names its tenant: our own (msp.homeTenantId) for the
    #          Internal phase, the client's onmicrosoft.com domain for the Tenant phase.
    $ours = $msp.homeTenantId
    $pocContacts = @($Client.poc | Where-Object { $_.email } | ForEach-Object {
            [ordered]@{ Organization = $ours; Name = "$($_.name) ($($Client.name))"; ExternalEmailAddress = $_.email }
        })
    $pocMembers = @($pocEmails | ForEach-Object { [ordered]@{ Organization = $ours; Identity = $msp.clientNotificationsDl; Member = $_ } })
    #   GOTCHA Exchange delegated sessions and account UPNs use the client's
    #          onmicrosoft.com domain, which the tech typed into the config.
    #          tenantId (GUID or domain) is only for the Graph sign-in.
    $onms = $Client.onmicrosoftDomain
    $adminInvocations = @(@($Settings.adminAccounts) | Where-Object { $_ } | ForEach-Object {
            @{ TenantId = $Client.tenantId; UpnPrefix = $_.upnPrefix; DisplayName = $_.displayName; Roles = @($_.roles); Domain = $onms; HuduCompanyId = [int]$Client.huduCompanyId }
        })
    $spfInvocations = @($Client.domains | ForEach-Object { @{ Domain = $_ } })
    $dkimInvocations = @($Client.domains | ForEach-Object { @{ Organization = $onms; Domain = $_ } })
    $folderName = $Client.name
    #endregion

    #region 2. Step definitions --------------------------------------------------
    #   WHAT   One entry per checklist line, in checklist order.
    #   WHY    Reading this top to bottom should match reading the Autotask
    #          checklist top to bottom. Manual steps stay in the list on purpose:
    #          the printed run is the tech's reminder of what is still theirs.
    #   GOTCHA $Params may be one hashtable or an array of them. A step with several
    #          invocations (one per POC, per domain, per admin account) runs its
    #          script once per hashtable, so every task script keeps a single job.
    $step = {
        param($Id, $Name, $Phase, $Kind, $Applies, $Script, $Params, $Sop, $Note, $Expect)
        $invocations = @()
        if ($Params -is [System.Collections.IDictionary]) { $invocations = @($Params) }
        elseif ($Params) { $invocations = @($Params | Where-Object { $_ }) }
        [pscustomobject]@{
            Id = $Id; Name = $Name; Phase = $Phase; Kind = $Kind; Applies = [bool]$Applies
            Script = $Script; Invocations = $invocations; SopUrl = $Sop; Note = $Note; Expect = $Expect
        }
    }
    $steps = @(
        # ---- 1 - Set Up Client Account, Contract & Internal Comms (our tenant) ----
        & $step '1.1' 'Update Client Primary Contact in Partner Dashboard' 'Internal' 'Manual' $true $null $null $sop1 'Franchise portal, no API.'
        & $step '1.2' 'Confirm client set as Managed Service & Customer in Autotask' 'Internal' 'Manual' $true $null $null $sop1 'Autotask REST API exists; candidate for a later psa/ script.'
        & $step '1.3' 'Assign correct contract in Autotask' 'Internal' 'Manual' $true $null $null $sop1 'Autotask REST API candidate.'
        & $step '1.4' 'Add exclusion contract if Non-Profit' 'Internal' 'Manual' $true $null $null $sop1 $null
        & $step '1.5' 'Set correct tax region in Autotask' 'Internal' 'Manual' $true $null $null $sop1 'Autotask REST API candidate.'
        & $step '1.6' "Create client alias $($Client.internalAlias) on $($msp.sharedClientsMailbox)" 'Internal' 'Auto' $true `
            'scripts/powershell/exchange/Add-M365MailboxAlias.ps1' ([ordered]@{ Organization = $ours; Mailbox = $msp.sharedClientsMailbox; Alias = $Client.internalAlias }) $sop1 $null
        & $step '1.7a' "Create folder '$folderName' under Inbox in $($msp.sharedClientsMailbox)" 'Internal' 'Auto' $true `
            'scripts/powershell/exchange/New-M365MailboxFolder.ps1' @{ TenantId = $msp.homeTenantId; Mailbox = $msp.sharedClientsMailbox; Name = $folderName } $sop1 $null
        & $step '1.7b' "Inbox rule: subject/body mentions '$($Client.name)' -> $folderName" 'Internal' 'Auto' $true `
            'scripts/powershell/exchange/New-M365InboxRule.ps1' ([ordered]@{ Organization = $ours; Mailbox = $msp.sharedClientsMailbox; Name = "Client - $($Client.name) (name)"; SubjectOrBodyContainsWords = @($Client.name); MoveToFolder = "Inbox\$folderName" }) $sop1 $null
        & $step '1.7c' "Inbox rule: sent to $($Client.internalAlias) -> $folderName" 'Internal' 'Auto' $true `
            'scripts/powershell/exchange/New-M365InboxRule.ps1' ([ordered]@{ Organization = $ours; Mailbox = $msp.sharedClientsMailbox; Name = "Client - $($Client.name) (alias)"; SentTo = @($Client.internalAlias); MoveToFolder = "Inbox\$folderName" }) $sop1 'Second rule because Exchange ANDs conditions inside one rule.'
        & $step '1.8' 'Create client account in Pax8' 'Internal' 'Manual' $true $null $null $sop1 'Pax8 has a partner API; candidate for a later csp/ script.'
        & $step '1.9' 'Set up Pax8 CSP agreement to client 365 tenant' 'Internal' 'Manual' $true $null $null $sop1 'Client must accept the Microsoft Customer Agreement; stays manual.'
        & $step '1.10' 'Set up Pax8 GDAP connection to client 365 tenant' 'Internal' 'Manual' $true $null $null $sop1 'Verified later by 5.7.'
        & $step '1.11a' 'Add client POC(s) as mail contacts in our tenant' 'Internal' 'Auto' ($pocEmails.Count -gt 0) `
            'scripts/powershell/exchange/New-M365MailContact.ps1' $pocContacts $sop1 'Skipped when the client config has no poc entries. One contact per POC.'
        & $step '1.11b' "Add client POC(s) to '$($msp.clientNotificationsDl)' distribution list" 'Internal' 'Auto' ($pocEmails.Count -gt 0) `
            'scripts/powershell/exchange/Add-M365DistributionListMember.ps1' $pocMembers $sop1 $null

        # ---- 5 - Configure & Secure Client 365 Tenant (client tenant) ----
        & $step '5.1' 'Review 365 accounts, remove unneeded ones' 'Tenant' 'Assisted' $true `
            'scripts/powershell/entra/Get-M365UserReview.ps1' @{ TenantId = $Client.tenantId; CsvPath = "runs/$($Client.shortName)-users.csv" } $sop5 'Script produces the review table (last sign-in, licenses, roles). Removal is a human decision; use the Entra portal or Remove-MgUser by hand.'
        & $step '5.2' 'Get admin rights release form signed for any retained admin access' 'Tenant' 'Manual' $true $null $null $sop5 'Use the IsAdmin column from 5.1 to know who needs a form.'
        & $step '5.3' 'Create break-glass account (Global Administrator, excluded from every Conditional Access policy)' 'Tenant' 'Auto' $true `
            'scripts/powershell/entra/New-M365BreakGlassAccount.ps1' @{ TenantId = $Client.tenantId; UpnPrefix = $bg.upnPrefix; DisplayName = $bg.displayName; PasswordLength = [int]$bg.passwordLength; Domain = $onms; HuduCompanyId = [int]$Client.huduCompanyId } $sop5 $(if (-not $hasHudu) { 'huduCompanyId is 0: password is shown once on screen instead of stored in Hudu.' })
        & $step '5.4' 'Create domain & 365 tenant admin accounts' 'Tenant' 'Auto' (@($Settings.adminAccounts).Count -gt 0) `
            'scripts/powershell/entra/New-M365AdminAccount.ps1' $adminInvocations $sop5 'One account per entry in settings.adminAccounts.'
        & $step '5.5' "Verify SPF record for $domain" 'Tenant' 'Assisted' $true `
            'scripts/powershell/mailauth/Test-M365SpfRecord.ps1' $spfInvocations $sop5 'Read-only check. Fixing SPF is a DNS change at the registrar.'
        & $step '5.6' "Set up DKIM for $domain" 'Tenant' 'Assisted' $true `
            'scripts/powershell/mailauth/Enable-M365Dkim.ps1' $dkimInvocations $sop5 'Creates the signing config and prints the two CNAMEs. Re-run after DNS is published to enable.'
        & $step '5.7' 'Connect in Augment & map GDAP relationship' 'Tenant' 'Assisted' $true `
            'scripts/powershell/partner/Get-M365GdapRelationship.ps1' @{ CustomerTenantId = $Client.tenantId } $sop5 'Script verifies GDAP is Active from our tenant. Augment mapping is manual.' {
            param($Output)
            #   WHY    Matched by tenant, never by name, and a step that finds nothing active fails.
            if (-not @($Output | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Status' -and "$($_.Status)" -eq 'active' }).Count) { 'No active GDAP relationship for this tenant.' }
        }
        & $step '5.8' 'Add American HelpDesk access (documented in Hudu)' 'Tenant' 'Manual' ([bool]$Client.americanHelpDesk) $null $null $sop5 'Their access model decides whether this becomes a New-M365AdminAccount entry.'
        & $step '5.9' "Add $($msp.supportEmail) as technical and security/compliance contact in tenant" 'Tenant' 'Assisted' $true `
            'scripts/powershell/entra/Set-M365TechnicalContact.ps1' @{ TenantId = $Client.tenantId; Email = $msp.supportEmail; IncludeSecurityCompliance = $true } $sop5 'Help desk card (Org settings > Organization profile) has no API; set it by hand.'
        & $step '5.10' "Add $($Client.internalAlias) as a hidden mail contact in tenant" 'Tenant' 'Auto' $true `
            'scripts/powershell/exchange/New-M365MailContact.ps1' @{ Organization = $onms; Name = $msp.name; ExternalEmailAddress = $Client.internalAlias; HiddenFromAddressLists = $true } $sop5 'External address is the client-specific alias (1.6) so replies file into the right folder. Set contactAddress in the client config to override.'
        & $step '5.11' "Create $itName@$domain with our alias as member" 'Tenant' 'Auto' $true `
            'scripts/powershell/exchange/New-M365DistributionList.ps1' @{ Organization = $onms; Name = $itName; PrimarySmtpAddress = "$itName@$domain"; Members = @($Client.internalAlias) } $sop5 $null
        & $step '5.12a' "Add $($msp.supportEmail) as a hidden mail contact in tenant" 'Tenant' 'Auto' $true `
            'scripts/powershell/exchange/New-M365MailContact.ps1' @{ Organization = $onms; Name = "$($msp.name) Support"; ExternalEmailAddress = $msp.supportEmail; HiddenFromAddressLists = $true } $sop5 'A distribution list can only contain recipients that exist in the tenant, so the external support address needs a contact first.'
        & $step '5.12b' "Create $alertsName@$domain with support email as member" 'Tenant' 'Auto' $true `
            'scripts/powershell/exchange/New-M365DistributionList.ps1' @{ Organization = $onms; Name = $alertsName; PrimarySmtpAddress = "$alertsName@$domain"; Members = @($msp.supportEmail) } $sop5 $null
        & $step '5.13' "Create $reportMailbox@$domain shared mailbox (ironScales)" 'Tenant' 'Auto' ([bool]$Client.ironScales) `
            'scripts/powershell/exchange/New-M365SharedMailbox.ps1' @{ Organization = $onms; Name = $reportMailbox; PrimarySmtpAddress = "$reportMailbox@$domain" } $sop5 'Skipped unless ironScales is true in the client config.'
        & $step '5.14' 'Send welcome letter to users' 'Tenant' 'Manual' $true $null $null $sop5 'Deferred: not automated yet. Send-M365TemplateMail.ps1 exists for when the letter text is approved.'
        & $step '5.15' 'Security baseline audit (Microsoft posture + MSP standard objects)' 'Tenant' 'Assisted' $true `
            'scripts/powershell/security/Test-M365SecurityBaseline.ps1' ([ordered]@{ TenantId = $Client.tenantId; Organization = $onms; PrimaryDomain = $domain; CsvPath = "runs/$($Client.shortName)-security-baseline.csv" }) $sop5 'Read-only. Fail rows name the remediation script; run those by hand after reading them.'
    )
    #endregion

    #region 3. Overrides from client config -------------------------------------
    #   WHAT   Honor contactAddress if the tech wants the contact to be clients@ itself.
    #   WHY    SOP #5 step 10 names the shared mailbox; SOP #1 says the alias is what
    #          joins the IT list. Default to the alias, allow the literal.
    if ($Client.PSObject.Properties.Name -contains 'contactAddress' -and $Client.contactAddress) {
        foreach ($s in $steps | Where-Object { $_.Id -in '5.10', '5.11' }) {
            foreach ($inv in $s.Invocations) {
                if ($inv.ContainsKey('ExternalEmailAddress')) { $inv.ExternalEmailAddress = $Client.contactAddress }
                if ($inv.ContainsKey('Members')) { $inv.Members = @($Client.contactAddress) }
            }
        }
    }
    #endregion

    return @($steps | Where-Object { $Phase -contains $_.Phase })
}

function Get-OnboardingGraphScopes {
    <#
    .SYNOPSIS
        Returns the delegated Graph scopes a phase of onboarding needs, so consent happens once.
    .PARAMETER Phase
        Internal, Tenant, or Partner (GDAP work in our partner tenant).
    .EXAMPLE
        Assert-M365Graph -TenantId $client.tenantId -Scopes (Get-OnboardingGraphScopes -Phase Tenant)
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a list of scopes; the plural is the honest name.')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Internal', 'Tenant', 'Partner')]
        [string]$Phase
    )
    switch ($Phase) {
        'Partner' { @('DelegatedAdminRelationship.ReadWrite.All', 'Group.Read.All', 'RoleManagement.Read.Directory', 'CrossTenantInformation.ReadBasic.All') }
        'Internal' { @('Mail.ReadWrite.Shared', 'User.Read') }
        'Tenant' {
            @('User.ReadWrite.All', 'Directory.Read.All', 'AuditLog.Read.All', 'Domain.Read.All',
                'RoleManagement.ReadWrite.Directory', 'RoleManagement.Read.Directory', 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess',
                'Organization.ReadWrite.All')
        }
    }
}

function Save-OnboardingRunRecord {
    <#
    .SYNOPSIS
        Writes what a run did (per step: status, detail, timestamp) to runs/<client>-<stamp>.json.
    .DESCRIPTION
        runs/ is gitignored. The record is what you paste from when closing the Autotask
        checklist, and what Test-ClientOnboarding compares against. Secrets are never in
        it: the scripts return passwords to the operator, not to the orchestrator record.
    .PARAMETER Client
        Client config.
    .PARAMETER Results
        Step result objects from the orchestrator.
    .PARAMETER RunsPath
        Folder to write to. Default <repo>/runs.
    .EXAMPLE
        Save-OnboardingRunRecord -Client $client -Results $results
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object]$Client,

        [Parameter(Mandatory)]
        [object[]]$Results,

        [Parameter()]
        [string]$RunsPath
    )
    if (-not $RunsPath) { $RunsPath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'runs' }
    $RunsPath = [IO.Path]::GetFullPath($RunsPath)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $RunsPath "$($Client.shortName)-$stamp.json"
    $record = [ordered]@{
        client    = $Client.name
        shortName = $Client.shortName
        tenantId  = $Client.tenantId
        startedAt = ($Results | Measure-Object -Property StartedAt -Minimum).Minimum
        endedAt   = (Get-Date).ToString('o')
        operator  = [Environment]::UserName
        steps     = @($Results | Select-Object Id, Name, Phase, Kind, Status, Detail, StartedAt)
    }
    if ($PSCmdlet.ShouldProcess($file, 'Write run record')) {
        if (-not (Test-Path $RunsPath)) { $null = New-Item -ItemType Directory -Path $RunsPath }
        $record | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding utf8
    }
    return $file
}

Export-ModuleMember -Function Get-OnboardingPlan, Get-OnboardingGraphScopes, Save-OnboardingRunRecord
