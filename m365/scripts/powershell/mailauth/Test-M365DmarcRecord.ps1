<#
.SYNOPSIS
    Reads a domain's DMARC record and prints the record to publish if there is none.
.DESCRIPTION
    Read-only, no sign-in. Follows the order in our 'DKIM and DMARC Setup - Exchange Online'
    SOP: SPF, then DKIM, then DMARC starting at p=none. If nothing is published it returns
    the monitoring-mode record and host name for the tech to add in DNS.
.PARAMETER Domain
    One or more domains to check.
.PARAMETER ReportMailbox
    Address for aggregate and forensic reports in the suggested record. Default dmarc@<domain>.
.EXAMPLE
    ./Test-M365DmarcRecord.ps1 -Domain contoso.com
.NOTES
    Requires: outbound HTTPS to the DoH resolver
    Status:   Tested 2026-10-16 against public domains
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string[]]$Domain,

    [Parameter()]
    [string]$ReportMailbox
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
process {
    foreach ($d in $Domain) {
        $params = @{ Domain = $d }
        if ($ReportMailbox) { $params.ReportMailbox = $ReportMailbox }
        $result = Get-DmarcAnalysis @params
        foreach ($finding in $result.Findings) { Write-Warning "[$d] $finding" }
        if (-not $result.Record) { Write-Warning "[$d] Publish TXT $($result.SuggestedHost) = $($result.SuggestedRecord)" }
        $result
    }
}
#endregion
