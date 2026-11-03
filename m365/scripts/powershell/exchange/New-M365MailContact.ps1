<#
.SYNOPSIS
    Creates a mail contact (external address) in a tenant, optionally hidden from the GAL.
.DESCRIPTION
    Onboarding checklist 1.11a (client POC in our tenant) and 5.10 / 5.12a (our alias and
    support address in the client tenant, hidden). Idempotent on the external address: an
    existing mail contact for that exact address is kept (and hidden if asked). If the
    address belongs to something else (a mailbox, a group), nothing is created or hidden
    and the output says so.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER Name
    Contact name.
.PARAMETER ExternalEmailAddress
    Address outside the tenant that mail is delivered to.
.PARAMETER DisplayName
    Defaults to -Name.
.PARAMETER HiddenFromAddressLists
    Hide from the global address list.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./New-M365MailContact.ps1 -Organization contoso.onmicrosoft.com -Name 'Example MSP' -ExternalEmailAddress contoso@msp.example -HiddenFromAddressLists -WhatIf
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
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$ExternalEmailAddress,

    [Parameter()]
    [string]$DisplayName,

    [Parameter()]
    [switch]$HiddenFromAddressLists,

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

#region 3. Create -----------------------------------------------------------------
$params = @{ Name = $Name; ExternalEmailAddress = $ExternalEmailAddress; HiddenFromAddressLists = $HiddenFromAddressLists }
if ($DisplayName) { $params.DisplayName = $DisplayName }
New-M365MailContact @params -WhatIf:$WhatIfPreference
#endregion
