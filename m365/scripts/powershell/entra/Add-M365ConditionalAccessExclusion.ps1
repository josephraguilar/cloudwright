<#
.SYNOPSIS
    Excludes a user from every Conditional Access policy (or the policies named).
.DESCRIPTION
    Used for break-glass accounts and for the rare service account that a policy must not
    touch. Each policy is read raw and the WHOLE users condition is sent back (every
    include/exclude list and the guest/external-user settings), then read back to confirm.
    One result per policy: Updated, Planned (-WhatIf), AlreadyExcluded, Skipped (no users
    condition) or Failed; on a failure it stops before the next policy and says which were
    done and which were not attempted. Idempotent.
.PARAMETER TenantId
    Tenant (GUID or any verified domain).
.PARAMETER UserPrincipalName
    The user to exclude.
.PARAMETER PolicyDisplayName
    Limit to these policies (exact names; each must match exactly one policy). Default all.
.PARAMETER PolicyId
    Limit to these policy ids. Use when two policies share a display name.
.EXAMPLE
    ./Add-M365ConditionalAccessExclusion.ps1 -TenantId contoso.onmicrosoft.com -UserPrincipalName breakglass@contoso.onmicrosoft.com -WhatIf
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.SignIns
    Graph scopes: User.Read.All, Policy.Read.All, Policy.ReadWrite.ConditionalAccess
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
    [string[]]$PolicyDisplayName,

    [Parameter()]
    [string[]]$PolicyId
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
Import-Module (Join-Path $modules 'EntraHelpers' 'EntraHelpers.psd1') -Force
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.Read.All', 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess'
#endregion

#region 3. Exclude ----------------------------------------------------------------
#   WHAT   Exactly one user by exact UPN (apostrophes escaped for the filter).
$found = @(Get-MgUser -Filter "userPrincipalName eq '$($UserPrincipalName.Replace("'", "''"))'" -Property id, userPrincipalName -ErrorAction Stop)
if ($found.Count -ne 1) { throw "Expected exactly one user $UserPrincipalName in tenant $TenantId, found $($found.Count). Nothing was changed." }
$params = @{ UserId = "$($found[0].Id)"; UserLabel = $UserPrincipalName }
if ($PolicyDisplayName) { $params.PolicyDisplayName = $PolicyDisplayName }
if ($PolicyId) { $params.PolicyId = $PolicyId }
Add-M365ConditionalAccessExclusion @params -WhatIf:$WhatIfPreference
#endregion
