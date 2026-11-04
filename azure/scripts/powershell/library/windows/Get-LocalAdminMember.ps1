<#
.SYNOPSIS
    Members of the local Administrators group.
.NOTES
    Status: Untested
#>
param()
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

$group = Get-LocalGroup -SID 'S-1-5-32-544'
Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue | ForEach-Object { '{0} ({1}, {2})' -f $_.Name, $_.ObjectClass, $_.PrincipalSource }
