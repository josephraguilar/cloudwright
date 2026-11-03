<#
.SYNOPSIS
    Shows DKIM signing state for a domain and whether its selector CNAMEs are live in DNS.
.DESCRIPTION
    Read-only. Needs an Exchange Online session in the tenant that owns the domain. Returns
    the exact CNAME targets from Exchange so they can be pasted into DNS; never guesses them.
    Status Unknown (with Error) means the config could not be read, which is not the same
    as "no config".
.PARAMETER Organization
    Tenant to read: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER Domain
    One or more accepted domains in that tenant.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Get-M365DkimStatus.ps1 -Organization contoso.onmicrosoft.com -Domain contoso.com
.NOTES
    Requires: ExchangeOnlineManagement
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string[]]$Domain,

    [Parameter()]
    [string]$SignInAs
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1') -Force

$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
#endregion

#region 3. Report -------------------------------------------------------------------
foreach ($d in $Domain) {
    $status = Get-M365DkimStatus -Domain $d
    if ($status.Status -eq 'Unknown') { Write-Warning "[$d] $($status.Error)" }
    elseif (-not $status.ConfigExists) { Write-Warning "[$d] No DKIM signing config. Run Enable-M365Dkim.ps1 to create it." }
    elseif (-not $status.ReadyToEnable) { Write-Warning "[$d] Publish CNAME selector1._domainkey -> $($status.Selector1Cname) and selector2._domainkey -> $($status.Selector2Cname)" }
    $status
}
#endregion
