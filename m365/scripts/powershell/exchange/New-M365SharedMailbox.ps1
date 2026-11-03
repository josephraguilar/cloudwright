<#
.SYNOPSIS
    Creates a shared mailbox and optionally grants Full Access (no automapping).
.DESCRIPTION
    Onboarding checklist 5.13 (911@ for ironScales reporting) and any later shared mailbox
    request. Idempotent on the SMTP address, and strict: an existing mailbox is kept only
    when it is a SHARED mailbox whose PRIMARY address is -PrimarySmtpAddress. If the address
    is an alias on someone's personal mailbox, a user mailbox or a group, the script stops,
    names the owner and grants nothing, so Full Access never lands on the wrong mailbox.
    A dry run lists the Full Access grants too.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER Name
    Mailbox name.
.PARAMETER PrimarySmtpAddress
    Mailbox address.
.PARAMETER FullAccess
    Users to grant Full Access.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./New-M365SharedMailbox.ps1 -Organization contoso.onmicrosoft.com -Name 911 -PrimarySmtpAddress 911@contoso.com -WhatIf
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
    [string[]]$FullAccess = @(),

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
Import-Module (Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1') -Force

$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
#endregion

#region 3. Create -----------------------------------------------------------------
New-M365SharedMailbox -Name $Name -PrimarySmtpAddress $PrimarySmtpAddress -FullAccess $FullAccess -WhatIf:$WhatIfPreference
#endregion
