<#
.SYNOPSIS
    Who holds admin roles, which roles, last sign-in and registered MFA methods.
.DESCRIPTION
    Read-only. Built on Get-M365UserReview filtered to role holders, with MFA methods
    included. Use it for the admin rights release form (onboarding 5.2) and for quarterly
    reviews. Optional CSV.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER CsvPath
    Also write to CSV (relative paths resolve from the repo root). Use runs/, the only folder git ignores.
.EXAMPLE
    ./Get-M365AdminReport.ps1 -TenantId contoso.onmicrosoft.com | Format-Table UserPrincipalName, Roles, LastSignIn, MfaMethods -Wrap
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.SignIns
    Graph scopes: User.Read.All, Directory.Read.All, AuditLog.Read.All, UserAuthenticationMethod.Read.All
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter()]
    [string]$CsvPath
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'EntraHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
if ($CsvPath) {
    #   GOTCHA Only runs/ is gitignored; a CSV of client data elsewhere in the repo can be committed.
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
    $csvFull = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($CsvPath)) { $CsvPath } else { Join-Path $repoRoot $CsvPath }))
    if (-not $csvFull.StartsWith((Join-Path $repoRoot 'runs') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "CSV $csvFull is outside the repo's runs/ folder, the only folder git ignores. It holds client data: keep it out of commits and shared folders (for example -CsvPath runs/<client>-admins.csv)."
    }
}
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.Read.All', 'Directory.Read.All', 'AuditLog.Read.All', 'UserAuthenticationMethod.Read.All', 'RoleManagement.Read.Directory'
#endregion

#region 3. Report -------------------------------------------------------------------
$rows = @(Get-M365UserReview -IncludeMfa | Where-Object IsAdmin | Select-Object DisplayName, UserPrincipalName, Enabled, Roles, LastSignIn, DaysSinceSignIn, MfaMethods, Licenses)
foreach ($r in $rows | Where-Object { -not $_.MfaMethods -or $_.MfaMethods.Count -eq 0 }) { Write-Warning "Admin $($r.UserPrincipalName) has no MFA method registered." }
if ($CsvPath) { $null = Export-M365Csv -Rows $rows -Path $CsvPath }
$rows
#endregion
