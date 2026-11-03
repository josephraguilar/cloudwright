<#
.SYNOPSIS
    Sets or disables an automatic reply on a mailbox.
.DESCRIPTION
    Same text for internal and external senders. Offboarding uses it to point senders to the right person.
.PARAMETER Identity
    The mailbox.
.PARAMETER Message
    Reply text (HTML allowed). Required unless -Disable.
.PARAMETER Disable
    Turn automatic replies off.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Set-M365MailboxAutoReply.ps1 -Organization contoso.onmicrosoft.com -Identity jane@contoso.com -Message 'Jane has left. Contact office@contoso.com.' -WhatIf
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
    [string]$Message,

    [Parameter()]
    [switch]$Disable,

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
$params = @{ Identity = $Identity; Disable = $Disable }
if ($Message) { $params.Message = $Message }
Set-M365MailboxAutoReply @params -WhatIf:$WhatIfPreference
#endregion
