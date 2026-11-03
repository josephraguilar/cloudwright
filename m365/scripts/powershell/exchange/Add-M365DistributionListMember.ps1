<#
.SYNOPSIS
    Adds a recipient to a distribution list unless already a member.
.DESCRIPTION
    Onboarding checklist 1.11b (client POC into our Client Notifications list) and any
    later "add X to the Y list" ticket. Idempotent. The list and the member must each match
    exactly one object (no wildcards); the change names both by primary SMTP address.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER Identity
    The list, by name or address.
.PARAMETER Member
    Recipient to add, by address or name.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Add-M365DistributionListMember.ps1 -Organization examplemsp.onmicrosoft.com -Identity 'Client Notifications' -Member jane@contoso.com -WhatIf
.NOTES
    Requires: ExchangeOnlineManagement
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$Identity,

    [Parameter(Mandatory)]
    [string]$Member,

    [Parameter()]
    [string]$SignInAs
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Sign in to exactly -Organization (verified live) before anything is read.
#   WHY    There is no "blank means our tenant": every run names the tenant it changes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
Import-Module (Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1') -Force

$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
#endregion

#region 3. Add -------------------------------------------------------------------------
Add-M365DistributionListMember -Identity $Identity -Member $Member -WhatIf:$WhatIfPreference
#endregion
