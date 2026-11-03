<#
.SYNOPSIS
    Assigns licenses to a user by SKU part number (SPB, SPE_E3, ...).
.DESCRIPTION
    Skips SKUs the user already has (all held = "AlreadyLicensed", nothing changes), refuses SKUs the tenant does not own, warns when no units are free. Idempotent.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER UserPrincipalName
    The user.
.PARAMETER Sku
    SKU part numbers; see reports/Get-M365LicenseReport.ps1 for the tenant's list.
.EXAMPLE
    ./Set-M365UserLicense.ps1 -TenantId contoso.onmicrosoft.com -UserPrincipalName jane@contoso.com -Sku SPB -WhatIf
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: User.ReadWrite.All, Organization.Read.All
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
    [string[]]$Sku
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
Add-M365UserLicense -UserPrincipalName $UserPrincipalName -Sku $Sku -WhatIf:$WhatIfPreference
#endregion
