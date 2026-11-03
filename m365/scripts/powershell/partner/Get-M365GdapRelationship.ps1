<#
.SYNOPSIS
    Lists GDAP relationships from our partner tenant, with roles, expiry and (optionally) group assignments.
.DESCRIPTION
    Read-only. Onboarding checklist 5.7 verification and the everyday "is GDAP still good for
    this client" question. Pass -IncludeAssignments to see which MSP security groups hold
    which roles on each relationship.
    Prefer -CustomerTenantId. -CustomerName must match the customer's display name exactly
    (case-insensitive, no wildcards): "ABC" never matches "ABC Plumbing". When nothing matches,
    it warns and returns nothing.
.PARAMETER CustomerName
    Exact customer display name (case-insensitive). Ignored for filtering when -CustomerTenantId is given.
.PARAMETER CustomerTenantId
    Customer tenant GUID or a domain (resolved). Preferred over -CustomerName.
.PARAMETER IncludeAssignments
    Also list access assignments.
.PARAMETER HomeTenantId
    Our partner tenant. Defaults to msp.homeTenantId.
.EXAMPLE
    ./Get-M365GdapRelationship.ps1 -CustomerTenantId contoso.onmicrosoft.com -IncludeAssignments | Format-List
.EXAMPLE
    ./Get-M365GdapRelationship.ps1 -CustomerName 'Contoso Dental'
.NOTES
    Requires: Microsoft.Graph.Identity.Partner, Microsoft.Graph.Identity.Governance
    Graph scopes: DelegatedAdminRelationship.Read.All, RoleManagement.Read.Directory
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter()]
    [string]$CustomerName,

    [Parameter()]
    [string]$CustomerTenantId,

    [Parameter()]
    [switch]$IncludeAssignments,

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
if ($CustomerName -match '[*?]') { throw "-CustomerName must be the exact customer name, without wildcards ('$CustomerName'). Or pass -CustomerTenantId." }
$null = Assert-M365Graph -TenantId $HomeTenantId -Scopes 'DelegatedAdminRelationship.Read.All', 'RoleManagement.Read.Directory'
#endregion

#region 3. Query ----------------------------------------------------------------
#   WHAT   Tenant id first (unambiguous). A name picks relationships only on an exact match,
#          and two different tenants with that same name are refused, not merged.
$relationships = @()
if ($CustomerTenantId) {
    $tid = Resolve-M365TenantId -TenantId $CustomerTenantId
    $relationships = @(Get-GdapRelationship -CustomerTenantId $tid -IncludeAssignments:$IncludeAssignments)
    if ($CustomerName -and $relationships.Count -gt 0 -and -not @($relationships | Where-Object { $_.Customer -ieq $CustomerName })) {
        Write-Warning "Tenant $tid is listed as '$($relationships[0].Customer)', not '$CustomerName'. Showing the tenant's relationships."
    }
    if ($relationships.Count -eq 0) { Write-Warning "No GDAP relationship with tenant $tid. The customer may not have accepted a request yet." }
} elseif ($CustomerName) {
    $all = @(Get-GdapRelationship)
    $exact = @($all | Where-Object { $_.Customer -ieq $CustomerName })
    $tenants = @($exact | ForEach-Object { $_.CustomerTenantId } | Sort-Object -Unique)
    if ($tenants.Count -gt 1) { throw "$($tenants.Count) different customer tenants are named '$CustomerName': $($tenants -join ', '). Pass -CustomerTenantId." }
    if ($tenants.Count -eq 1) {
        $relationships = @(if ($IncludeAssignments) { Get-GdapRelationship -CustomerTenantId $tenants[0] -IncludeAssignments } else { $exact })
    } else {
        $similar = @($all | Where-Object { $_.Customer -and $_.Customer.IndexOf($CustomerName, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { $_.Customer } | Sort-Object -Unique | Select-Object -First 5)
        Write-Warning "No GDAP relationship for a customer named exactly '$CustomerName'.$(if ($similar.Count) { " Similar names: $($similar -join '; '). Use the exact name or -CustomerTenantId." } else { ' The customer may not have accepted a request yet.' })"
    }
} else {
    $relationships = @(Get-GdapRelationship -IncludeAssignments:$IncludeAssignments)
    if ($relationships.Count -eq 0) { Write-Warning 'No GDAP relationships in our partner tenant.' }
}
foreach ($r in $relationships | Where-Object { $_.Status -ne 'active' }) { Write-Warning "Relationship '$($r.DisplayName)' for $($r.Customer) is $($r.Status)." }
$relationships
#endregion
