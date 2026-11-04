<#
.SYNOPSIS
    Free space on every fixed disk; exit 1 when one is below the threshold.
.PARAMETER MinFreePercent
    Report a problem below this percentage free. Default 10.
.NOTES
    Status: Untested
#>
param([string]$MinFreePercent = '10')
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

$min = [int]$MinFreePercent
$low = 0
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $pct = if ($_.Size) { [math]::Round(100 * $_.FreeSpace / $_.Size, 1) } else { 0 }
    if ($pct -lt $min) { $low++ }
    '{0} {1:N1} GB free of {2:N1} GB ({3}%){4}' -f $_.DeviceID, ($_.FreeSpace / 1GB), ($_.Size / 1GB), $pct, $(if ($pct -lt $min) { '  LOW' } else { '' })
}
if ($low -gt 0) { exit 1 }
