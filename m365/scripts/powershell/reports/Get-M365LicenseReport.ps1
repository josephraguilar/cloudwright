<#
.SYNOPSIS
    License report: purchased vs assigned vs available per SKU, with warning and suspended units.
.DESCRIPTION
    Read-only. The monthly true-up and the "do we have a spare E3" question. Optional CSV.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER CsvPath
    Also write to CSV (relative paths resolve from the repo root). Use runs/, the only folder git ignores.
.EXAMPLE
    ./Get-M365LicenseReport.ps1 -TenantId contoso.onmicrosoft.com | Format-Table Sku, Total, Assigned, Available
.NOTES
    Requires: Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: Organization.Read.All
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
        Write-Warning "CSV $csvFull is outside the repo's runs/ folder, the only folder git ignores. It holds client data: keep it out of commits and shared folders (for example -CsvPath runs/<client>-licenses.csv)."
    }
}
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'Organization.Read.All'
#endregion

#region 3. Report -------------------------------------------------------------------
$rows = @(Get-M365LicenseSummary | Sort-Object Sku)
if ($CsvPath) { $null = Export-M365Csv -Rows $rows -Path $CsvPath }
$rows
#endregion
