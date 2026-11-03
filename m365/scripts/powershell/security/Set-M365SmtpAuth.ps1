<#
.SYNOPSIS
    Turns SMTP AUTH On or Off for the whole organization (-State Off disables it).
.DESCRIPTION
    Baseline check smtpAuthDisabled (expects -State Off). Idempotent: no change when the
    tenant already matches. Devices that must relay (printers, scanners) get a per-mailbox
    exception by hand: Set-CASMailbox -Identity <mailbox> -SmtpClientAuthenticationDisabled $false.
.PARAMETER State
    Off disables SMTP AUTH organization-wide (the baseline); On re-enables it.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Set-M365SmtpAuth.ps1 -Organization contoso.onmicrosoft.com -State Off -WhatIf
.NOTES
    Requires: ExchangeOnlineManagement
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
#   WHY    On/Off instead of the old mandatory [bool] -Disabled: no double negative, and
#          the GUI and console can build it from a dropdown.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('On', 'Off')]
    [string]$State,

    [Parameter(Mandatory)]
    [string]$Organization,

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
foreach ($m in 'M365Helpers', 'ExchangeHelpers', 'SecurityHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
#endregion

#region 3. Apply -------------------------------------------------------------------
Set-M365SmtpAuth -Disabled ($State -eq 'Off') -WhatIf:$WhatIfPreference
#endregion
