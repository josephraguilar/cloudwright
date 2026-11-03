<#
.SYNOPSIS
    Adds a user to Entra groups (security or Microsoft 365) by display name.
.DESCRIPTION
    Every group must match exactly one group by its exact display name, or be given by object id; two groups with the same name stop the run before any change and are listed with their ids. Distribution lists, mail-enabled security, dynamic and on-premises-synced groups are refused (those are Exchange or AD: exchange/Add-M365DistributionListMember.ps1). Existing memberships are skipped.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER UserPrincipalName
    The user.
.PARAMETER GroupName
    Exact group display names or object ids.
.EXAMPLE
    ./Add-M365GroupMember.ps1 -TenantId contoso.onmicrosoft.com -UserPrincipalName jane@contoso.com -GroupName 'All Staff' -WhatIf
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: GroupMember.ReadWrite.All, User.Read.All
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
    [string[]]$GroupName
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'EntraHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'GroupMember.ReadWrite.All', 'User.Read.All'
#endregion

#region 3. Apply -------------------------------------------------------------------
Add-M365GroupMember -UserPrincipalName $UserPrincipalName -GroupName $GroupName -WhatIf:$WhatIfPreference
#endregion
