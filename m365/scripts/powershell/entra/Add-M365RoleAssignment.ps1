<#
.SYNOPSIS
    Assigns an Entra directory role to a user by UPN, if not already assigned.
.DESCRIPTION
    Permanent assignment at tenant scope through the unified role API. Use it when a client
    asks for someone to become Exchange admin, or to fix an admin account built by hand.
    The user must match the UPN exactly and each role name exactly one role. An assignment
    scoped to an administrative unit does not count as already assigned.
.PARAMETER TenantId
    Tenant (GUID or any verified domain).
.PARAMETER UserPrincipalName
    The user.
.PARAMETER RoleName
    One or more role display names, e.g. 'Exchange Administrator'.
.EXAMPLE
    ./Add-M365RoleAssignment.ps1 -TenantId contoso.onmicrosoft.com -UserPrincipalName jane@contoso.com -RoleName 'Exchange Administrator'
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.Governance
    Graph scopes: User.Read.All, RoleManagement.ReadWrite.Directory
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$UserPrincipalName,

    [Parameter(Mandatory)]
    [string[]]$RoleName
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
Import-Module (Join-Path $modules 'EntraHelpers' 'EntraHelpers.psd1') -Force
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.Read.All', 'RoleManagement.ReadWrite.Directory'
#endregion

#region 3. Assign ---------------------------------------------------------------
$found = @(Get-MgUser -Filter "userPrincipalName eq '$($UserPrincipalName.Replace("'", "''"))'" -Property id, userPrincipalName -ErrorAction Stop)
if ($found.Count -ne 1) { throw "Expected exactly one user $UserPrincipalName in tenant $TenantId, found $($found.Count). Nothing was changed." }
foreach ($role in $RoleName) {
    Add-M365RoleAssignment -PrincipalId "$($found[0].Id)" -PrincipalLabel $UserPrincipalName -RoleName $role -WhatIf:$WhatIfPreference |
        Select-Object @{ n = 'UserPrincipalName'; e = { $UserPrincipalName } }, RoleName, Assigned, AlreadyAssigned, WhatIf
}
#endregion
