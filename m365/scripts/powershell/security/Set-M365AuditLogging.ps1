<#
.SYNOPSIS
    Turns on unified audit log ingestion and default mailbox auditing.
.DESCRIPTION
    Baseline checks unifiedAuditLog and mailboxAuditing. Idempotent: no change when the
    tenant already matches. Each setting that is off is shown as its own command before it runs.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Set-M365AuditLogging.ps1 -Organization contoso.onmicrosoft.com -WhatIf
.NOTES
    Requires: ExchangeOnlineManagement
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
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
Enable-M365AuditLogging -WhatIf:$WhatIfPreference
#endregion
