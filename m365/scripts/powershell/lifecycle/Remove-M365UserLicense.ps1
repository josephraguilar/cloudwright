<#
.SYNOPSIS
    Removes all directly assigned licenses from a user. Group-based licenses are reported.
.DESCRIPTION
    Offboarding step after the mailbox is converted to shared. Idempotent. This script does not
    look at the mailbox: removing the license from a user mailbox deletes the mail after the
    30-day grace period. For a leaver use Invoke-M365UserOffboarding.ps1, which checks the
    mailbox is shared (and has no archive, hold or >50 GB size) before removing licenses.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER UserPrincipalName
    The user.
.EXAMPLE
    ./Remove-M365UserLicense.ps1 -TenantId contoso.onmicrosoft.com -UserPrincipalName jane@contoso.com -WhatIf
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: User.ReadWrite.All, Organization.Read.All
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$UserPrincipalName
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'EntraHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.ReadWrite.All', 'Organization.Read.All'
#endregion

#region 3. Apply -------------------------------------------------------------------
Remove-M365UserLicense -UserPrincipalName $UserPrincipalName -WhatIf:$WhatIfPreference
#endregion
