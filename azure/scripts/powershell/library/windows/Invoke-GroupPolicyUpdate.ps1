<#
.SYNOPSIS
    Refresh Group Policy (computer and user) now.
.NOTES
    Status: Untested
#>
param()
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

gpupdate.exe /force /wait:120 2>&1 | Where-Object { $_ -and $_ -notmatch '^\s*$' }
