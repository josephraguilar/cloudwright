<#
.SYNOPSIS
    Lists customers that already have a GDAP relationship with us.
.DESCRIPTION
    Read-only, partner tenant. A customer with no relationship yet does not appear; for them,
    pass the tenant id or a domain to Start-M365GdapOnboarding.ps1 and it validates it.
.PARAMETER Name
    Filter by display name (contains).
.PARAMETER TenantId
    Filter to one tenant GUID.
.PARAMETER HomeTenantId
    Our partner tenant. Defaults to msp.homeTenantId.
.EXAMPLE
    ./Get-M365GdapCustomer.ps1 -Name contoso
.NOTES
    Requires: Microsoft.Graph.Identity.Partner
    Graph scopes: DelegatedAdminRelationship.Read.All
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Name,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$HomeTenantId
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'GdapHelpers' 'GdapHelpers.psd1') -Force
$settings = Get-M365Settings
if (-not $HomeTenantId) { $HomeTenantId = $settings.msp.homeTenantId }
$null = Assert-M365Graph -TenantId $HomeTenantId -Scopes 'DelegatedAdminRelationship.Read.All'
#endregion

#region 3. Query ----------------------------------------------------------------
$params = @{}
if ($Name) { $params.Name = $Name }
if ($TenantId) { $params.TenantId = $TenantId }
Get-GdapCustomer @params
#endregion
