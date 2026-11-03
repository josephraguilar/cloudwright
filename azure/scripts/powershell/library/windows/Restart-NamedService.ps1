<#
.SYNOPSIS
    Restart one Windows service and report its state.
.PARAMETER Name
    Service name, for example Spooler.
.NOTES
    Status: Untested
#>
param([string]$Name = 'Spooler')
$s = Get-Service -Name $Name -ErrorAction SilentlyContinue
if (-not $s) { "No service named $Name."; exit 1 }
Restart-Service -Name $Name -Force
Start-Sleep -Seconds 3
"$Name is $((Get-Service -Name $Name).Status)."
