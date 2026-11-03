<#
.SYNOPSIS
    Creates the DKIM signing config for a domain and enables signing once its CNAMEs are in DNS.
.DESCRIPTION
    Onboarding checklist 5.6. First run: creates the (disabled, 2048-bit) config so Exchange
    generates the selector values, prints the two CNAMEs to publish, and stops. Second run,
    after DNS propagates: enables signing. Safe to run as many times as needed. Stops and
    changes nothing for a domain whose current DKIM config cannot be read.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER Domain
    One or more accepted domains in that tenant.
.PARAMETER KeySize
    1024 or 2048. Default 2048.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Enable-M365Dkim.ps1 -Organization contoso.onmicrosoft.com -Domain contoso.com -WhatIf
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
    [string[]]$Domain,

    [Parameter()]
    [ValidateSet(1024, 2048)]
    [int]$KeySize = 2048,

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

#region 3. Create and enable -----------------------------------------------------
foreach ($d in $Domain) {
    Enable-M365Dkim -Domain $d -KeySize $KeySize -WhatIf:$WhatIfPreference
}
#endregion
