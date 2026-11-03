<#
.SYNOPSIS
    Forwards a mailbox to another address (keeping a copy), or clears forwarding.
.DESCRIPTION
    Internal targets use a recipient reference, external ones an SMTP address. A target that does not resolve to a recipient in this tenant is external, and external forwarding is refused unless -AllowExternal (so a typo like manager@cotnoso.com never becomes silent external forwarding). External automatic forwarding may also be blocked by the outbound spam policy (the baseline recommends that).
.PARAMETER Identity
    The mailbox.
.PARAMETER ForwardTo
    Target address. Omit with -Clear.
.PARAMETER NoCopy
    Do not keep a copy in the mailbox.
.PARAMETER Clear
    Remove forwarding.
.PARAMETER AllowExternal
    Allow -ForwardTo to be an address outside this tenant. Without it an external target is refused.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Set-M365MailboxForwarding.ps1 -Organization contoso.onmicrosoft.com -Identity jane@contoso.com -ForwardTo manager@contoso.com -WhatIf
.EXAMPLE
    ./Set-M365MailboxForwarding.ps1 -Organization contoso.onmicrosoft.com -Identity jane@contoso.com -ForwardTo jane.doe@gmail.example -AllowExternal -WhatIf
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
    [string]$ForwardTo,

    [Parameter()]
    [switch]$NoCopy,

    [Parameter()]
    [switch]$Clear,

    [Parameter()]
    [switch]$AllowExternal,

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
$params = @{ Identity = $Identity; NoCopy = $NoCopy; Clear = $Clear }
if ($ForwardTo) { $params.ForwardTo = $ForwardTo }
if ($AllowExternal) { $params.AllowExternal = $true }
Set-M365MailboxForwarding @params -WhatIf:$WhatIfPreference
#endregion
