<#
.SYNOPSIS
    Read-only verification of a client's onboarding: does every automatable item actually exist?
.DESCRIPTION
    The 'Verification' section of SOPs #1 and #5 as code. Checks our tenant (alias, folder,
    inbox rules, POC contacts, GDAP) and then the client tenant (break-glass with GA and CA
    exclusions, admin accounts, SPF, DKIM, technical contact, hidden contact, IT@ and
    alerts@ lists with members, 911@ mailbox). Changes nothing. Returns one row per check
    with Pass / Fail / Skip and a detail string you can paste into the ticket.
.PARAMETER Client
    Client short name. Loads config/clients/<Client>.local.json.
.PARAMETER ConfigPath
    Explicit client config path.
.PARAMETER Phase
    Internal (our tenant) and/or Tenant (client tenant). Default both.
.EXAMPLE
    ./Test-ClientOnboarding.ps1 -Client contoso | Format-Table Id, Result, Check, Detail -Wrap
.NOTES
    Requires: Microsoft.Graph, ExchangeOnlineManagement
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Client,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [ValidateSet('Internal', 'Tenant')]
    [string[]]$Phase = @('Internal', 'Tenant')
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'ExchangeHelpers', 'EntraHelpers', 'OnboardingHelpers') {
    Import-Module (Join-Path $modules $m "$m.psd1") -Force
}
$settings = Get-M365Settings
$clientParams = @{ Settings = $settings }
if ($ConfigPath) { $clientParams.Path = $ConfigPath } elseif ($Client) { $clientParams.Name = $Client } else { throw 'Pass -Client <shortName> or -ConfigPath <file>.' }
$c = Get-M365ClientConfig @clientParams
#   WHY    Check the config names one tenant before reading anything, so a typo cannot
#          produce a report that mixes two clients.
$identifiers = [ordered]@{ tenantId = $c.tenantId; onmicrosoftDomain = $c.onmicrosoftDomain }
$domainLabels = @()
foreach ($d in @($c.domains)) { $label = "domain $d"; $identifiers[$label] = $d; $domainLabels += $label }
$null = Assert-M365SameTenant -Identifier $identifiers -AllowUnresolved $domainLabels
$plan = Get-OnboardingPlan -Client $c -Settings $settings
$adminUpn = if ($settings.msp.adminUpn -notmatch '^<') { $settings.msp.adminUpn } else { $null }
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Id, [string]$Check, [bool]$Pass, [string]$Detail, [switch]$Skip)
    $checks.Add([pscustomobject]@{ Id = $Id; Check = $Check; Result = if ($Skip) { 'Skip' } elseif ($Pass) { 'Pass' } else { 'Fail' }; Detail = $Detail })
}
function Test-Safely {
    param([string]$Id, [string]$Check, [scriptblock]$Body)
    try { & $Body } catch { Add-Check -Id $Id -Check $Check -Pass $false -Detail "Error: $($_.Exception.Message)" }
}
function Test-StepApplicable { param([string]$Id) $s = $plan | Where-Object Id -eq $Id | Select-Object -First 1; return ($s -and $s.Applies) }
#endregion

#region 3. Our tenant ---------------------------------------------------------
if ($Phase -contains 'Internal') {
    Disconnect-M365Tenant -Confirm:$false
    $null = Assert-M365Graph -TenantId $settings.msp.homeTenantId -Scopes 'Mail.Read.Shared', 'DelegatedAdminRelationship.Read.All'
    $null = Assert-M365Exchange -Organization $settings.msp.homeTenantId -UserPrincipalName $adminUpn -ExpectedTenantId $settings.msp.homeTenantId
    $shared = $settings.msp.sharedClientsMailbox

    Test-Safely '1.6' "Alias $($c.internalAlias) on $shared" {
        $mbx = Get-Mailbox -Identity $shared
        $has = [bool]($mbx.EmailAddresses | Where-Object { $_ -ieq "smtp:$($c.internalAlias)" })
        Add-Check '1.6' "Alias $($c.internalAlias) on $shared" $has $(if ($has) { 'present' } else { 'missing' })
    }
    Test-Safely '1.7a' "Folder '$($c.name)' under Inbox in $shared" {
        $folder = Get-MgUserMailFolderChildFolder -UserId $shared -MailFolderId inbox -All | Where-Object DisplayName -eq $c.name
        Add-Check '1.7a' "Folder '$($c.name)' under Inbox in $shared" ([bool]$folder) $(if ($folder) { 'present' } else { 'missing' })
    }
    Test-Safely '1.7' "Inbox rules for $($c.name) in $shared" {
        $rules = @(Get-InboxRule -Mailbox $shared | Where-Object { $_.Name -like "Client - $($c.name)*" })
        Add-Check '1.7' "Inbox rules for $($c.name) in $shared" ($rules.Count -ge 2) "$($rules.Count) rule(s): $(($rules | ForEach-Object Name) -join '; ')"
    }
    if (Test-StepApplicable '1.11a') {
        foreach ($poc in $c.poc | Where-Object email) {
            Test-Safely '1.11' "POC $($poc.email) is a contact and in '$($settings.msp.clientNotificationsDl)'" {
                $contact = Get-Recipient -Identity $poc.email -ErrorAction SilentlyContinue
                $member = $false
                if ($contact) { $member = [bool](Get-DistributionGroupMember -Identity $settings.msp.clientNotificationsDl -ResultSize Unlimited | Where-Object PrimarySmtpAddress -eq $poc.email) }
                Add-Check '1.11' "POC $($poc.email) is a contact and in '$($settings.msp.clientNotificationsDl)'" ($contact -and $member) "contact=$([bool]$contact) member=$member"
            }
        }
    } else { Add-Check '1.11' 'POC contacts' $false 'No poc entries in client config.' -Skip }
    Test-Safely '5.7' "GDAP relationship active for $($c.name)" {
        $rels = @(Get-M365GdapRelationship -CustomerTenantId (Resolve-M365TenantId -TenantId $c.tenantId))
        $active = @($rels | Where-Object Status -eq 'active')
        Add-Check '5.7' "GDAP relationship active for $($c.name)" ($active.Count -gt 0) "$($active.Count) active of $($rels.Count); roles: $(($active | ForEach-Object Roles | Select-Object -Unique) -join ', ')"
    }
}
#endregion

#region 4. Client tenant -----------------------------------------------------------
if ($Phase -contains 'Tenant') {
    Disconnect-M365Tenant -Confirm:$false
    $null = Assert-M365Graph -TenantId $c.tenantId -Scopes 'User.Read.All', 'Directory.Read.All', 'RoleManagement.Read.Directory', 'Policy.Read.All', 'Domain.Read.All', 'Organization.Read.All'
    $null = Assert-M365Exchange -Organization $c.onmicrosoftDomain -UserPrincipalName $adminUpn -ExpectedTenantId $c.tenantId
    $initial = $c.onmicrosoftDomain
    $domain = $c.primaryDomain

    Test-Safely '5.3' 'Break-glass account: exists, Global Administrator, excluded from all CA policies' {
        $upn = "$($settings.breakGlass.upnPrefix)@$initial"
        $user = Get-MgUser -Filter "userPrincipalName eq '$upn'" | Select-Object -First 1
        $isGa = $false; $notExcluded = @()
        if ($user) {
            $ga = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Global Administrator'" | Select-Object -First 1
            $isGa = [bool](Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($user.Id)' and roleDefinitionId eq '$($ga.Id)'")
            $notExcluded = @(Get-MgIdentityConditionalAccessPolicy -All | Where-Object { $_.Conditions.Users.ExcludeUsers -notcontains $user.Id } | ForEach-Object DisplayName)
        }
        Add-Check '5.3' 'Break-glass account: exists, Global Administrator, excluded from all CA policies' ($user -and $isGa -and $notExcluded.Count -eq 0) "$upn exists=$([bool]$user) GA=$isGa notExcludedFrom=$($notExcluded -join '; ')"
    }
    foreach ($acct in @($settings.adminAccounts)) {
        Test-Safely '5.4' "Admin account $($acct.upnPrefix) with roles $($acct.roles -join ', ')" {
            $upn = "$($acct.upnPrefix)@$initial"
            $user = Get-MgUser -Filter "userPrincipalName eq '$upn'" | Select-Object -First 1
            $missing = @()
            if ($user) {
                foreach ($roleName in $acct.roles) {
                    $def = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$roleName'" | Select-Object -First 1
                    if (-not (Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($user.Id)' and roleDefinitionId eq '$($def.Id)'")) { $missing += $roleName }
                }
            }
            Add-Check '5.4' "Admin account $($acct.upnPrefix) with roles $($acct.roles -join ', ')" ($user -and $missing.Count -eq 0) "$upn exists=$([bool]$user) missingRoles=$($missing -join '; ')"
        }
    }
    foreach ($d in $c.domains) {
        Test-Safely '5.5' "SPF for $d" { $spf = Get-SpfAnalysis -Domain $d; Add-Check '5.5' "SPF for $d" ($spf.Status -ne 'Fail') "$($spf.Status) lookups=$($spf.LookupCount) $($spf.Findings -join '; ')" }
        Test-Safely '5.6' "DKIM enabled for $d" { $dk = Get-M365DkimStatus -Domain $d; Add-Check '5.6' "DKIM enabled for $d" ($dk.Status -eq 'Pass') "config=$($dk.ConfigExists) enabled=$($dk.Enabled) cnamesPublished=$($dk.Selector1Published -and $dk.Selector2Published)" }
        Test-Safely '5.6b' "DMARC published for $d" { $dm = Get-DmarcAnalysis -Domain $d; Add-Check '5.6b' "DMARC published for $d" ($dm.Status -ne 'Fail') "$($dm.Status) p=$($dm.Policy)" }
    }
    Test-Safely '5.9' "Technical contact includes $($settings.msp.supportEmail)" {
        $org = Get-MgOrganization | Select-Object -First 1
        $has = $org.TechnicalNotificationMails -contains $settings.msp.supportEmail
        Add-Check '5.9' "Technical contact includes $($settings.msp.supportEmail)" $has "technical=$($org.TechnicalNotificationMails -join '; ')"
    }
    $contactAddress = ($plan | Where-Object Id -eq '5.10').Invocations[0].ExternalEmailAddress
    Test-Safely '5.10' "Hidden mail contact for $contactAddress" {
        $r = Get-Recipient -Identity $contactAddress -ErrorAction SilentlyContinue
        $hidden = $false
        if ($r) { $hidden = (Get-MailContact -Identity $r.Identity).HiddenFromAddressListsEnabled }
        Add-Check '5.10' "Hidden mail contact for $contactAddress" ($r -and $hidden) "exists=$([bool]$r) hidden=$hidden"
    }
    foreach ($id in '5.11', '5.12b') {
        $inv = ($plan | Where-Object Id -eq $id).Invocations[0]
        Test-Safely $id "List $($inv.PrimarySmtpAddress) with member(s) $($inv.Members -join ', ')" {
            $g = Get-DistributionGroup -Identity $inv.PrimarySmtpAddress -ErrorAction SilentlyContinue
            $missing = @()
            if ($g) {
                $members = @(Get-DistributionGroupMember -Identity $g.Identity -ResultSize Unlimited)
                foreach ($m in $inv.Members) {
                    $rec = Get-Recipient -Identity $m -ErrorAction SilentlyContinue
                    if (-not $rec -or -not ($members | Where-Object Identity -eq $rec.Identity)) { $missing += $m }
                }
            }
            Add-Check $id "List $($inv.PrimarySmtpAddress) with member(s) $($inv.Members -join ', ')" ($g -and $missing.Count -eq 0) "exists=$([bool]$g) externalSendersAllowed=$(if ($g) { -not $g.RequireSenderAuthenticationEnabled }) missingMembers=$($missing -join '; ')"
        }
    }
    if (Test-StepApplicable '5.13') {
        $inv = ($plan | Where-Object Id -eq '5.13').Invocations[0]
        Test-Safely '5.13' "Shared mailbox $($inv.PrimarySmtpAddress)" {
            $m = Get-Mailbox -Identity $inv.PrimarySmtpAddress -ErrorAction SilentlyContinue
            Add-Check '5.13' "Shared mailbox $($inv.PrimarySmtpAddress)" ($m -and $m.RecipientTypeDetails -eq 'SharedMailbox') "exists=$([bool]$m) type=$(if ($m) { $m.RecipientTypeDetails })"
        }
    } else { Add-Check '5.13' "Shared mailbox $domain (ironScales)" $false 'ironScales is false in client config.' -Skip }
}
#endregion

#region 5. Output -----------------------------------------------------------------
Disconnect-M365Tenant -Confirm:$false
$fails = @($checks | Where-Object Result -eq 'Fail')
Write-Verbose "$($checks.Count) checks, $($fails.Count) failed."
$checks.ToArray()
#endregion
