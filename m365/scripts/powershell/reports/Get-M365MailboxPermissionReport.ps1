<#
.SYNOPSIS
    Every non-default Full Access, Send As and Send on Behalf grant across the tenant's mailboxes.
.DESCRIPTION
    Read-only. Who can read whose mail. Slow on large tenants (two calls per mailbox).
    A mailbox whose permissions could not be read gets a row with the Error column filled
    (and a warning) instead of being left out. Optional CSV.
.PARAMETER Organization
    Tenant to read: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER RecipientTypeDetails
    Limit to mailbox types, e.g. SharedMailbox.
.PARAMETER CsvPath
    Also write to CSV (relative paths resolve from the repo root). Use runs/, the only folder git ignores.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Get-M365MailboxPermissionReport.ps1 -Organization contoso.onmicrosoft.com -RecipientTypeDetails SharedMailbox
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
    [string[]]$RecipientTypeDetails,

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
        Write-Warning "CSV $csvFull is outside the repo's runs/ folder, the only folder git ignores. It holds client data: keep it out of commits and shared folders (for example -CsvPath runs/<client>-mailbox-permissions.csv)."
    }
}
$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
#endregion

#region 3. Report -------------------------------------------------------------------
$params = @{}
if ($RecipientTypeDetails) { $params.RecipientTypeDetails = $RecipientTypeDetails }
$rows = @(Get-M365MailboxPermissionAudit @params | Sort-Object Mailbox, Permission, Trustee)
if ($CsvPath) { $null = Export-M365Csv -Rows $rows -Path $CsvPath }
$rows
#endregion
