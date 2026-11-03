<#
.SYNOPSIS
    Lists every user in a tenant with licenses, admin roles, last sign-in and (optionally) MFA methods.
.DESCRIPTION
    Onboarding checklist 5.1 and 5.2. Read-only. The output is the table you review before
    deciding which accounts to remove and who must sign the admin rights release form.
    Removal stays a human action. Optionally writes a CSV for the ticket.

    Roles include those held through a role-assignable group and PIM-eligible ones
    (EligibleRoles). IsAdmin is 'Unknown' when the roles could not be read; treat those
    rows as possible admins.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER IncludeMfa
    Also list registered authentication methods per user (one extra Graph call each).
.PARAMETER StaleDays
    Flag users with no sign-in in this many days. Default 90.
.PARAMETER CsvPath
    Write the table here as CSV. Relative paths resolve from the repo root.
.EXAMPLE
    ./Get-M365UserReview.ps1 -TenantId contoso.onmicrosoft.com | Where-Object Stale | Format-Table
.EXAMPLE
    ./Get-M365UserReview.ps1 -TenantId contoso.onmicrosoft.com -IncludeMfa -CsvPath runs/contoso-users.csv
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.Governance, Microsoft.Graph.Identity.SignIns (for -IncludeMfa)
    Graph scopes: User.Read.All, Directory.Read.All, RoleManagement.Read.Directory, AuditLog.Read.All, UserAuthenticationMethod.Read.All
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter()]
    [switch]$IncludeMfa,

    [Parameter()]
    [int]$StaleDays = 90,

    [Parameter()]
    [string]$CsvPath
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'EntraHelpers' 'EntraHelpers.psd1') -Force

$scopes = @('User.Read.All', 'Directory.Read.All', 'RoleManagement.Read.Directory', 'AuditLog.Read.All')
if ($IncludeMfa) { $scopes += 'UserAuthenticationMethod.Read.All' }
$null = Assert-M365Graph -TenantId $TenantId -Scopes $scopes
#endregion

#region 3. Review -------------------------------------------------------------------
$rows = @(Get-M365UserReview -IncludeMfa:$IncludeMfa -StaleDays $StaleDays)
if ($CsvPath) {
    if (-not [IO.Path]::IsPathRooted($CsvPath)) { $CsvPath = Join-Path $PSScriptRoot '..' '..' '..' $CsvPath }
    $dir = Split-Path $CsvPath -Parent
    if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    $rows | Select-Object DisplayName, UserPrincipalName, Enabled, UserType, Synced,
        @{ n = 'Licenses'; e = { $_.Licenses -join ';' } }, @{ n = 'Roles'; e = { $_.Roles -join ';' } }, @{ n = 'EligibleRoles'; e = { $_.EligibleRoles -join ';' } },
        IsAdmin, LastSignIn, DaysSinceSignIn, Stale, @{ n = 'MfaMethods'; e = { $_.MfaMethods -join ';' } }, Created |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
    Write-Verbose "Wrote $($rows.Count) users to $CsvPath."
}
$admins = @($rows | Where-Object { $_.IsAdmin -eq $true })
$unknown = @($rows | Where-Object { "$($_.IsAdmin)" -eq 'Unknown' })
$stale = @($rows | Where-Object Stale)
Write-Verbose "$($rows.Count) users, $($admins.Count) with admin roles, $($unknown.Count) with roles unknown, $($stale.Count) stale (>= $StaleDays days or never signed in)."
$rows
#endregion
