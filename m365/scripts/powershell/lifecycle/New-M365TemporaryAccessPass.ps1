<#
.SYNOPSIS
    Issues a Temporary Access Pass so a user can sign in once and register MFA without a shared password.
.DESCRIPTION
    Needs the Temporary Access Pass method enabled in the tenant's authentication methods policy. The pass is printed once.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER UserPrincipalName
    The user.
.PARAMETER LifetimeHours
    Validity in hours. Default 8.
.PARAMETER Reusable
    Allow repeated use within the lifetime.
.EXAMPLE
    ./New-M365TemporaryAccessPass.ps1 -TenantId contoso.onmicrosoft.com -UserPrincipalName jane@contoso.com
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: UserAuthenticationMethod.ReadWrite.All
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
    [ValidateRange(1, 192)]
    [int]$LifetimeHours = 8,

    [Parameter()]
    [switch]$Reusable
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'EntraHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'UserAuthenticationMethod.ReadWrite.All'
#endregion

#region 3. Apply -------------------------------------------------------------------
$result = New-M365TemporaryAccessPass -UserPrincipalName $UserPrincipalName -LifetimeHours $LifetimeHours -Reusable:$Reusable -WhatIf:$WhatIfPreference
if ($result.Pass) { Write-Warning "Temporary Access Pass for $($result.UserPrincipalName), valid until $($result.ExpiresAt) (shown once): $($result.Pass)" }
$result | Select-Object UserPrincipalName, ExpiresAt, UsableOnce, Issued
#endregion
