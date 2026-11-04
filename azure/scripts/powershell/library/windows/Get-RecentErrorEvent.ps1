<#
.SYNOPSIS
    Error and critical events from the System and Application logs in the last hours.
.PARAMETER Hours
    How far back. Default 24.
.PARAMETER Max
    Most events to show. Default 40.
.NOTES
    Status: Untested
#>
param([string]$Hours = '24', [string]$Max = '40')
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

$since = (Get-Date).AddHours(-[int]$Hours)
Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = $since } -MaxEvents ([int]$Max) -ErrorAction SilentlyContinue |
    ForEach-Object { '{0:yyyy-MM-dd HH:mm} {1} {2} ({3}): {4}' -f $_.TimeCreated, $_.LogName, $_.ProviderName, $_.Id, (($_.Message -split "`n")[0]).Trim() }
