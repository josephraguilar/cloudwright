<#
.SYNOPSIS
    Converts a user mailbox to a shared mailbox so the mail stays and the license can go.
.DESCRIPTION
    Offboarding step. Idempotent. Warns when the mailbox is over 50 GB (still needs a license).
    The result's IsShared is $true only when the mailbox was read back as shared after a real
    run; remove the license only after that (Invoke-M365UserOffboarding.ps1 checks it, plus
    archive, holds and size, before removing licenses).
.PARAMETER Identity
    The mailbox (address or UPN).
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./ConvertTo-M365SharedMailbox.ps1 -Organization contoso.onmicrosoft.com -Identity jane@contoso.com -WhatIf
.NOTES
    Requires: ExchangeOnlineManagement
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Identity,

    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter()]
    [string]$SignInAs
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'ExchangeHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
#endregion

#region 3. Apply -------------------------------------------------------------------
ConvertTo-M365SharedMailbox -Identity $Identity -WhatIf:$WhatIfPreference
#endregion
