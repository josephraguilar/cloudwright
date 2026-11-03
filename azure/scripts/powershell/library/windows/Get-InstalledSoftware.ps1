<#
.SYNOPSIS
    Installed programs (machine-wide), optionally filtered by name.
.PARAMETER Filter
    Part of a program name, for example Chrome. Empty lists everything.
.NOTES
    Status: Untested
#>
param([string]$Filter = '')
$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and (-not $Filter -or $_.DisplayName -like "*$Filter*") } |
    Sort-Object DisplayName -Unique | ForEach-Object { '{0} | {1} | {2}' -f $_.DisplayName, $_.DisplayVersion, $_.Publisher }
