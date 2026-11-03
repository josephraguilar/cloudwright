<#
.SYNOPSIS
    Read-only security audit of a tenant against our baseline: MFA, legacy auth, audit logging, forwarding, DKIM, admins, and more.
.DESCRIPTION
    Collects facts over Graph and Exchange Online, compares them to config/baselines/security
    (local or example), and returns one row per check with Pass / Fail / Unknown, severity,
    the actual value and the remediation (usually a script in this repo). Changes nothing.
    Two groups of checks: Microsoft security posture, and the MSP standard setup
    (break-glass with GA and CA exclusion, mspadmin, hidden contacts, IT@ and MSPalerts@
    lists, technical contact). The MSP checks need the client's alias and domain, so pass
    -Client to take everything from the client config. Onboarding checklist 5.15.

    The Graph tenant (-TenantId) and the Exchange organization (-Organization) must be the
    same tenant or the audit stops before reading anything, so one report never mixes two
    clients. The break-glass account is looked up on the tenant's initial
    (<name>.onmicrosoft.com) domain as verified by the Exchange session, even when
    -Organization is a custom domain. A check whose data could not be read is Unknown, never
    Pass.
.PARAMETER Client
    Client short name (config/clients/<name>.local.json). Supplies TenantId, Organization,
    the client alias and the primary domain.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain) for Graph. Not needed with -Client.
.PARAMETER Organization
    Tenant to read in Exchange Online: its onmicrosoft.com domain or any verified domain. Required unless -Client supplies it or -SkipExchange is given.
.PARAMETER ContactAddress
    The client's alias on our clients@ mailbox, for the MSP contact and list checks. From -Client when given.
.PARAMETER PrimaryDomain
    The client's mail domain, for the list checks. From -Client when given.
.PARAMETER BaselinePath
    Override the baseline file.
.PARAMETER SkipExchange
    Graph facts only.
.PARAMETER CsvPath
    Also write the rows to CSV (relative paths resolve from the repo root). Use runs/, the only folder git ignores.
.PARAMETER SignInAs
    Partner account for the Exchange sign-in. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Test-M365SecurityBaseline.ps1 -Client contoso | Format-Table Result, Severity, Title, Actual -Wrap
.EXAMPLE
    ./Test-M365SecurityBaseline.ps1 -TenantId contoso.onmicrosoft.com -Organization contoso.onmicrosoft.com -CsvPath runs/contoso-baseline.csv
.NOTES
    Requires: Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users, ExchangeOnlineManagement
    Graph scopes: Policy.Read.All, Directory.Read.All, Domain.Read.All, User.Read.All, RoleManagement.Read.Directory
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Client,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$Organization,

    [Parameter()]
    [string]$ContactAddress,

    [Parameter()]
    [string]$PrimaryDomain,

    [Parameter()]
    [string]$BaselinePath,

    [Parameter()]
    [switch]$SkipExchange,

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [string]$SignInAs
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Resolve the tenant (from -Client or the parameters), then sign in to Graph and
#          to Exchange in that same tenant, verified.
#   WHY    A Graph tenant and an Exchange org from two different clients would produce one
#          report about two tenants. Assert-M365Exchange -ExpectedTenantId stops that.
#   GOTCHA -Organization is not Mandatory here only because -Client supplies it; a missing
#          one still stops the script (it never means "our tenant").
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'ExchangeHelpers', 'SecurityHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
if ($CsvPath) {
    #   GOTCHA Only runs/ is gitignored; a CSV of client data elsewhere in the repo can be committed.
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
    $csvFull = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($CsvPath)) { $CsvPath } else { Join-Path $repoRoot $CsvPath }))
    if (-not $csvFull.StartsWith((Join-Path $repoRoot 'runs') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "CSV $csvFull is outside the repo's runs/ folder, the only folder git ignores. It holds client data: keep it out of commits and shared folders (for example -CsvPath runs/<client>-baseline.csv)."
    }
}
$baselineParams = @{}
if ($BaselinePath) { $baselineParams.Path = $BaselinePath }
$baseline = Get-M365SecurityBaseline @baselineParams
$clientConfig = $null
if ($Client) {
    $clientConfig = Get-M365ClientConfig -Name $Client -Settings $settings
    if (-not $TenantId) { $TenantId = $clientConfig.tenantId }
    if (-not $Organization) { $Organization = $clientConfig.onmicrosoftDomain }
    if (-not $ContactAddress) { $ContactAddress = $clientConfig.internalAlias }
    if (-not $PrimaryDomain) { $PrimaryDomain = $clientConfig.primaryDomain }
}
if (-not $TenantId) { throw 'Pass -Client <shortName> or -TenantId.' }
if (-not $SkipExchange -and -not $Organization) { throw 'Pass -Organization <client>.onmicrosoft.com for the Exchange checks, or -SkipExchange.' }
if (-not $ContactAddress -or -not $PrimaryDomain) { Write-Warning 'No -Client (or -ContactAddress/-PrimaryDomain): the MSP contact and list checks will show Unknown.' }
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'Policy.Read.All', 'Directory.Read.All', 'Domain.Read.All', 'User.Read.All', 'RoleManagement.Read.Directory'
$initialDomain = $null
if (-not $SkipExchange) {
    $exchange = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs -ExpectedTenantId $TenantId
    $initialDomain = $exchange.InitialDomain
}
#endregion

#region 3. Collect and compare -----------------------------------------------------
#   GOTCHA OnmicrosoftDomain is the session's verified initial domain, never -Organization
#          (which may be a custom domain). With -SkipExchange it is looked up in Graph.
$factParams = @{ SkipExchange = $SkipExchange }
if ($settings) { $factParams.Settings = $settings }
if ($ContactAddress) { $factParams.ContactAddress = $ContactAddress }
if ($PrimaryDomain) { $factParams.PrimaryDomain = $PrimaryDomain }
if ($initialDomain) { $factParams.OnmicrosoftDomain = $initialDomain }
$collected = Get-M365SecurityFact @factParams
$rows = Compare-M365SecurityBaseline -Facts $collected.Facts -Baseline $baseline -Errors $collected.Errors
foreach ($e in $collected.Errors.GetEnumerator()) { Write-Warning "Check '$($e.Key)' could not be collected: $($e.Value)" }
$fail = @($rows | Where-Object Result -eq 'Fail'); $unknown = @($rows | Where-Object Result -eq 'Unknown')
Write-Verbose "$($rows.Count) checks: $($fail.Count) fail, $($unknown.Count) unknown, $($rows.Count - $fail.Count - $unknown.Count) pass. Baseline: $($baseline.name)."
if ($CsvPath) { $null = Export-M365Csv -Rows $rows -Path $CsvPath }
$rows
#endregion
