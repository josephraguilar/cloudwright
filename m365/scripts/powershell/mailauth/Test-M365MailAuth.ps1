<#
.SYNOPSIS
    One-page SPF + DKIM + DMARC report for a domain.
.DESCRIPTION
    Composes Get-SpfAnalysis, Get-M365DkimStatus and Get-DmarcAnalysis into a single row
    per domain. Use it on an onboarding, after a DNS change, or when a client reports mail
    landing in junk. DKIM needs an Exchange session; pass -SkipDkim for a DNS-only check
    (it then does not sign in at all). Read-only.
.PARAMETER Organization
    Tenant to read for DKIM: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings). Not used with -SkipDkim.
.PARAMETER Domain
    One or more domains.
.PARAMETER SkipDkim
    Do not sign in to Exchange; SPF and DMARC only.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Test-M365MailAuth.ps1 -Organization contoso.onmicrosoft.com -Domain contoso.com | Format-List
.NOTES
    Requires: ExchangeOnlineManagement unless -SkipDkim
    Status:   Untested (SPF/DMARC half tested 2026-10-16)
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string[]]$Domain,

    [Parameter()]
    [switch]$SkipDkim,

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

if (-not $SkipDkim) {
    $settings = try { Get-M365Settings } catch { $null }
    if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
    $null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
}
#endregion

#region 3. Report -------------------------------------------------------------------
foreach ($d in $Domain) {
    $spf = Get-SpfAnalysis -Domain $d
    $dmarc = Get-DmarcAnalysis -Domain $d
    $dkim = if ($SkipDkim) { $null } else { Get-M365DkimStatus -Domain $d }
    $dkimFinding = if (-not $dkim) { @() }
                   elseif ($dkim.Status -eq 'Unknown') { @($dkim.Error) }
                   elseif (-not $dkim.ConfigExists) { @('No DKIM signing config. Run Enable-M365Dkim.ps1.') }
                   elseif (-not $dkim.ReadyToEnable) { @("DKIM CNAMEs not published: $($dkim.Selector1Cname), $($dkim.Selector2Cname)") }
                   else { @() }
    [pscustomobject]@{
        Domain      = $d
        Spf         = $spf.Status
        SpfLookups  = $spf.LookupCount
        Dkim        = if ($dkim) { $dkim.Status } else { 'Skipped' }
        DkimEnabled = if ($dkim) { $dkim.Enabled } else { $null }
        Dmarc       = $dmarc.Status
        DmarcPolicy = $dmarc.Policy
        Findings    = @($spf.Findings + $dmarc.Findings + $dkimFinding)
    }
}
#endregion
