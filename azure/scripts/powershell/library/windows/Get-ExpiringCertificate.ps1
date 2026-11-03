<#
.SYNOPSIS
    Machine certificates that expire within the given days (Personal and
    Remote Desktop stores).
.PARAMETER Days
    Look-ahead in days. Default 30.
.NOTES
    Status: Untested
#>
param([string]$Days = '30')
$limit = (Get-Date).AddDays([int]$Days)
$hits = foreach ($store in 'Cert:\LocalMachine\My', 'Cert:\LocalMachine\Remote Desktop') {
    Get-ChildItem $store -ErrorAction SilentlyContinue | Where-Object { $_.NotAfter -lt $limit } |
        ForEach-Object { '{0:yyyy-MM-dd} {1} ({2}) in {3}' -f $_.NotAfter, $_.Subject, $_.Thumbprint, $store }
}
if (@($hits).Count -eq 0) { "Nothing expires in the next $Days days." } else { $hits }
