<#
.SYNOPSIS
    Checks a domain's SPF record for the things that break mail from Exchange Online.
.DESCRIPTION
    Read-only, no sign-in. Resolves the TXT record over DNS-over-HTTPS and reports: record
    count, whether include:spf.protection.outlook.com is present, the all mechanism, the
    recursive DNS lookup count against the limit of 10, and a Pass / Warn / Fail status.
    A top-level redirect=<domain> is followed (its lookups count toward the 10).
    Onboarding checklist 5.5. Fixing anything it finds is a DNS change at the registrar.
.PARAMETER Domain
    One or more domains to check.
.EXAMPLE
    ./Test-M365SpfRecord.ps1 -Domain contoso.com
.EXAMPLE
    ./Test-M365SpfRecord.ps1 -Domain contoso.com, contoso.org | Format-Table Domain, Status, LookupCount, Findings
.NOTES
    Requires: nothing beyond PowerShell 7 and outbound HTTPS to the DoH resolver
    Status:   Tested 2026-10-16 against public domains (no tenant needed)
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string[]]$Domain
)
#endregion

#region 2. Setup --------------------------------------------------------------
begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $modules = Join-Path $PSScriptRoot '..' 'modules'
    Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
    Import-Module (Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1') -Force
}
#endregion

#region 3. Analyze ---------------------------------------------------------------
#   WHAT   One analysis object per domain.
#   WHY    The module does the parsing so the same logic serves the console, the
#          orchestrator and Test-M365MailAuth.ps1.
process {
    foreach ($d in $Domain) {
        $result = Get-SpfAnalysis -Domain $d
        foreach ($finding in $result.Findings) { Write-Warning "[$d] $finding" }
        $result
    }
}
#endregion
