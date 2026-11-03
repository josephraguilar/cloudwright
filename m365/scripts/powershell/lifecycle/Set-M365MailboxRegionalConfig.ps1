<#
.SYNOPSIS
    Sets a mailbox's language and time zone so calendars and folder names are right from day one.
.DESCRIPTION
    New mailboxes sit in UTC until the user picks a zone. Idempotent.
.PARAMETER Identity
    The mailbox.
.PARAMETER TimeZone
    Windows time zone id. Default Pacific Standard Time.
.PARAMETER Language
    Culture. Default en-US.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Set-M365MailboxRegionalConfig.ps1 -Organization contoso.onmicrosoft.com -Identity jane@contoso.com -WhatIf
.NOTES
    Requires: ExchangeOnlineManagement
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Identity,

    [Parameter()]
    [string]$TimeZone = 'Pacific Standard Time',

    [Parameter()]
    [string]$Language = 'en-US',

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
$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
#endregion

#region 3. Apply -------------------------------------------------------------------
Set-M365MailboxRegionalConfig -Identity $Identity -TimeZone $TimeZone -Language $Language -WhatIf:$WhatIfPreference
#endregion
