<#
.SYNOPSIS
    Adds a secondary SMTP address to a mailbox.
.DESCRIPTION
    Onboarding checklist 1.6: attach <client>@<our domain> to our clients@ shared mailbox so
    vendor and service mail for that client lands with us. Also the everyday "add an alias
    to Jane's mailbox" ticket. Idempotent; the mailbox must match exactly one mailbox, and
    the script refuses if the address belongs to another recipient. Existing addresses are kept.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER Mailbox
    Target mailbox, by address or name.
.PARAMETER Alias
    Full SMTP address to add.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Add-M365MailboxAlias.ps1 -Organization examplemsp.onmicrosoft.com -Mailbox clients@msp.example -Alias contoso@msp.example -WhatIf
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
    [string]$Mailbox,

    [Parameter(Mandatory)]
    [string]$Alias,

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

#region 3. Add -------------------------------------------------------------------------
Add-M365MailboxAlias -Mailbox $Mailbox -Alias $Alias -WhatIf:$WhatIfPreference
#endregion
