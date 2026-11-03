<#
.SYNOPSIS
    Turns Security Defaults On or Off in a tenant (MFA for everyone, legacy auth blocked).
.DESCRIPTION
    Baseline checks mfaEnforced and legacyAuthBlocked for tenants without Conditional Access
    licensing. Turning On is refused while Conditional Access policies exist (Microsoft blocks
    it anyway); turning Off needs -Force because it removes MFA enforcement unless CA covers
    it. A dry run (-WhatIf) signs in with the same scopes as the real run (so the real run
    needs no second sign-in) and changes nothing.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER State
    On or Off.
.PARAMETER Force
    Allow turning Security Defaults Off.
.EXAMPLE
    ./Set-M365SecurityDefaults.ps1 -TenantId contoso.onmicrosoft.com -State On -WhatIf
.NOTES
    Requires: Microsoft.Graph.Identity.SignIns
    Graph scopes: Policy.Read.All, Policy.ReadWrite.ConditionalAccess
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
#   WHY    On/Off instead of a mandatory [bool]: the GUI and console can build it from a
#          dropdown, and the command line reads plainly.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidateSet('On', 'Off')]
    [string]$State,

    [Parameter()]
    [switch]$Force
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'ExchangeHelpers', 'SecurityHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess'
#endregion

#region 3. Apply -------------------------------------------------------------------
Set-M365SecurityDefault -Enabled ($State -eq 'On') -Force:$Force -WhatIf:$WhatIfPreference
#endregion
