<#
.SYNOPSIS
    Restart one Windows service and report its state.
.PARAMETER Name
    Service name, for example Spooler.
.NOTES
    Status: Untested
#>
param([string]$Name = 'Spooler')
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

$s = Get-Service -Name $Name -ErrorAction SilentlyContinue
if (-not $s) { "No service named $Name."; exit 1 }
Restart-Service -Name $Name -Force
Start-Sleep -Seconds 3
"$Name is $((Get-Service -Name $Name).Status)."
