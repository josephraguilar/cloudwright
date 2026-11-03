<#
.SYNOPSIS
    Adds our support address to a tenant's technical (and optionally security) notification contacts.
.DESCRIPTION
    Onboarding checklist 5.9, the half that has an API. Microsoft sends service health and
    tenant notices to these addresses. Existing contacts are kept. The help desk card in
    the admin center (Org settings > Organization profile > Help desk information) has no
    public API, so this script prints a reminder for it.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER Email
    Address to add. Defaults to msp.supportEmail from settings.
.PARAMETER IncludeSecurityCompliance
    Also add to the security & compliance notification list.
.EXAMPLE
    ./Set-M365TechnicalContact.ps1 -TenantId contoso.onmicrosoft.com -IncludeSecurityCompliance
.NOTES
    Requires: Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: Organization.ReadWrite.All
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter()]
    [string]$Email,

    [Parameter()]
    [switch]$IncludeSecurityCompliance
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'EntraHelpers' 'EntraHelpers.psd1') -Force
if (-not $Email) { $Email = (Get-M365Settings).msp.supportEmail }
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'Organization.ReadWrite.All'
#endregion

#region 3. Update ------------------------------------------------------------------
$result = Set-M365TechnicalContact -Email $Email -IncludeSecurityCompliance:$IncludeSecurityCompliance -WhatIf:$WhatIfPreference
Write-Warning 'Still manual: Microsoft 365 admin center > Settings > Org settings > Organization profile > Help desk information. Add our name, phone and support address there.'
$result
#endregion
