<#
.SYNOPSIS
    Blocks a user's sign-in and revokes their sessions. Never deletes.
.DESCRIPTION
    Offboarding step 1, or the first move on a compromised account. Idempotent.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER UserPrincipalName
    The user to block.
.PARAMETER SkipRevoke
    Block only; leave existing sessions alone.
.EXAMPLE
    ./Disable-M365UserSignIn.ps1 -TenantId contoso.onmicrosoft.com -UserPrincipalName jane@contoso.com -WhatIf
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Users.Actions
    Graph scopes: User.ReadWrite.All, User.RevokeSessions.All
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$UserPrincipalName,

    [Parameter()]
    [switch]$SkipRevoke
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'EntraHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.ReadWrite.All', 'User.RevokeSessions.All'
#endregion

#region 3. Apply -------------------------------------------------------------------
Disable-M365UserSignIn -UserPrincipalName $UserPrincipalName -SkipRevoke:$SkipRevoke -WhatIf:$WhatIfPreference
#endregion
