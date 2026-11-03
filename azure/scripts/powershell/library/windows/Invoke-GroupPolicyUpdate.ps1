<#
.SYNOPSIS
    Refresh Group Policy (computer and user) now.
.NOTES
    Status: Untested
#>
param()
gpupdate.exe /force /wait:120 2>&1 | Where-Object { $_ -and $_ -notmatch '^\s*$' }
