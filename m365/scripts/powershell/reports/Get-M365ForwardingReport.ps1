<#
.SYNOPSIS
    Mailboxes that forward mail, and (optionally) inbox rules that forward or redirect, with external targets flagged.
.DESCRIPTION
    Read-only. External forwarding is the classic sign of a compromised mailbox and a data
    leak path. Mailbox-level forwarding is fast; -IncludeInboxRules is one call per mailbox.
    Forwarding to a mail contact or mail user whose address is outside the tenant counts as
    External. A mailbox whose rules (or a target that) could not be read is never skipped:
    it gets a row with the Error column filled and a warning, because a mailbox the report
    could not see must not look clean.
.PARAMETER Organization
    Tenant to read: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER IncludeInboxRules
    Also inspect inbox rules.
.PARAMETER ExternalOnly
    Return only external targets, plus every row that could not be checked (Error).
.PARAMETER CsvPath
    Also write to CSV (relative paths resolve from the repo root). Use runs/, the only folder git ignores.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Get-M365ForwardingReport.ps1 -Organization contoso.onmicrosoft.com -IncludeInboxRules -ExternalOnly
.NOTES
    Requires: ExchangeOnlineManagement
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter()]
    [switch]$IncludeInboxRules,

    [Parameter()]
    [switch]$ExternalOnly,

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [string]$SignInAs
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'ExchangeHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
if ($CsvPath) {
    #   GOTCHA Only runs/ is gitignored; a CSV of client data elsewhere in the repo can be committed.
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
    $csvFull = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($CsvPath)) { $CsvPath } else { Join-Path $repoRoot $CsvPath }))
    if (-not $csvFull.StartsWith((Join-Path $repoRoot 'runs') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "CSV $csvFull is outside the repo's runs/ folder, the only folder git ignores. It holds client data: keep it out of commits and shared folders (for example -CsvPath runs/<client>-forwarding.csv)."
    }
}
$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
#endregion

#region 3. Report -------------------------------------------------------------------
#   WHAT   External rows and rows that could not be checked are both worth a look.
#   GOTCHA External is $null on an Error row (unknown), so -ExternalOnly keeps Error rows.
$rows = @(Get-M365ForwardingAudit -IncludeInboxRules:$IncludeInboxRules)
if ($ExternalOnly) { $rows = @($rows | Where-Object { $_.External -or $_.Error }) }
foreach ($r in $rows | Where-Object External) { Write-Warning "$($r.Mailbox) forwards to external $($r.Target) via $($r.Source)$(if ($r.Rule) { " '$($r.Rule)'" })" }
if ($CsvPath) { $null = Export-M365Csv -Rows $rows -Path $CsvPath }
$rows
#endregion
