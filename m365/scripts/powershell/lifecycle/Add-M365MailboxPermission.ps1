<#
.SYNOPSIS
    Grants a user Full Access (and optionally Send As) on a mailbox.
.DESCRIPTION
    Idempotent. Used in offboarding to hand a departed user's mailbox to their manager, and for the everyday shared-mailbox access ticket.
.PARAMETER Identity
    The mailbox.
.PARAMETER User
    Who gets access.
.PARAMETER SendAs
    Also grant Send As.
.PARAMETER AutoMapping
    Let Outlook open it automatically (off by default).
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Add-M365MailboxPermission.ps1 -Organization contoso.onmicrosoft.com -Identity jane@contoso.com -User manager@contoso.com -WhatIf
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
    [string]$User,

    [Parameter()]
    [switch]$SendAs,

    [Parameter()]
    [switch]$AutoMapping,

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
Add-M365MailboxPermission -Identity $Identity -User $User -SendAs:$SendAs -AutoMapping:$AutoMapping -WhatIf:$WhatIfPreference
#endregion
