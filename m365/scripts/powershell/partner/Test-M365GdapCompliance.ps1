<#
.SYNOPSIS
    Read-only: compares a customer's GDAP relationships and group assignments against our template.
.DESCRIPTION
    The safe first thing to run for any customer. Reports State (NoRelationship,
    PendingApproval, Compliant, MissingAssignments, MissingRoles, Expired), the roles covered
    and missing, the group assignments missing, warnings (overlap, expiry) and the proposed
    actions. Changes nothing. Start-M365GdapOnboarding.ps1 runs this first and acts on it.
.PARAMETER CustomerTenantId
    Customer tenant GUID or a verified domain (resolved).
.PARAMETER TemplatePath
    Override the template file (default from partner.gdapTemplate).
.PARAMETER HomeTenantId
    Our partner tenant. Defaults to msp.homeTenantId.
.EXAMPLE
    ./Test-M365GdapCompliance.ps1 -CustomerTenantId contoso.onmicrosoft.com | Format-List State, CoveredRoles, MissingRoles, MissingAssignments, Warnings, ProposedActions
.NOTES
    Requires: Microsoft.Graph.Identity.Partner, Microsoft.Graph.Identity.Governance
    Graph scopes: DelegatedAdminRelationship.Read.All, RoleManagement.Read.Directory
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CustomerTenantId,

    [Parameter()]
    [string]$TemplatePath,

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
$templateParams = @{ Settings = $settings }
if ($TemplatePath) { $templateParams.Path = $TemplatePath }
$template = Get-GdapTemplate @templateParams
$tenantGuid = Resolve-M365TenantId -TenantId $CustomerTenantId
$null = Assert-M365Graph -TenantId $HomeTenantId -Scopes 'DelegatedAdminRelationship.Read.All', 'RoleManagement.Read.Directory'
#endregion

#region 3. Compare ------------------------------------------------------------------
$result = Test-GdapCompliance -CustomerTenantId $tenantGuid -Template $template
foreach ($w in $result.Warnings) { Write-Warning $w }
foreach ($a in $result.ProposedActions) { Write-Verbose "Proposed: [$($a.Action)] $($a.Detail)" }
$result
#endregion
