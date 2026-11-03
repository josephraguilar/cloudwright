<#
.SYNOPSIS
    Creates a distribution list and makes sure the given members are in it.
.DESCRIPTION
    Onboarding checklist 5.11 (IT@) and 5.12b (alerts@). Accepts external senders by default
    because these lists exist to receive vendor and monitoring mail. Members that are
    outside addresses must already exist as mail contacts (see New-M365MailContact.ps1).
    Idempotent on the SMTP address, and strict: an existing distribution list is kept only
    when that address is its PRIMARY address; if the address belongs to anything else (an
    alias of another list, a mailbox, a security group) the script stops and names it. When
    an existing list's sender restriction differs from -RequireSenderAuthentication, the
    output warns instead of changing it.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER Name
    List name.
.PARAMETER PrimarySmtpAddress
    List address.
.PARAMETER Members
    Recipients to ensure are members.
.PARAMETER RequireSenderAuthentication
    Internal senders only.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./New-M365DistributionList.ps1 -Organization contoso.onmicrosoft.com -Name IT -PrimarySmtpAddress IT@contoso.com -Members contoso@msp.example -WhatIf
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
    [string]$PrimarySmtpAddress,

    [Parameter()]
    [string[]]$Members = @(),

    [Parameter()]
    [switch]$RequireSenderAuthentication,

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
New-M365DistributionList -Name $Name -PrimarySmtpAddress $PrimarySmtpAddress -Members $Members `
    -RequireSenderAuthentication:$RequireSenderAuthentication -WhatIf:$WhatIfPreference
#endregion
