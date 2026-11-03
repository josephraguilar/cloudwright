<#
.SYNOPSIS
    Set the Windows time zone.
.PARAMETER TimeZoneId
    A Windows time zone ID, for example Pacific Standard Time.
.NOTES
    Status: Untested
#>
param([string]$TimeZoneId = 'UTC')
$tz = Get-TimeZone -ListAvailable | Where-Object Id -eq $TimeZoneId
if (-not $tz) { "Unknown time zone ID '$TimeZoneId'."; exit 1 }
Set-TimeZone -Id $TimeZoneId
"Time zone is now $((Get-TimeZone).Id)."
