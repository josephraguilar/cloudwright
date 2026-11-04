<#
.SYNOPSIS
    Set the Windows time zone.
.PARAMETER TimeZoneId
    A Windows time zone ID, for example Pacific Standard Time.
.NOTES
    Status: Untested
#>
param([string]$TimeZoneId = 'UTC')
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

$tz = Get-TimeZone -ListAvailable | Where-Object Id -eq $TimeZoneId
if (-not $tz) { "Unknown time zone ID '$TimeZoneId'."; exit 1 }
Set-TimeZone -Id $TimeZoneId
"Time zone is now $((Get-TimeZone).Id)."
