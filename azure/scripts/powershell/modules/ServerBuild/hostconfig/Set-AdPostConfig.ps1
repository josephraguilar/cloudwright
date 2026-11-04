<#
.SYNOPSIS
    Runs INSIDE a new domain controller after its reboot: DNS forwarder to Azure
    DNS so the DC resolves internet names, then proves the domain answers.
#>
param(
    [string]$Forwarder = '168.63.129.16'
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

$ErrorActionPreference = 'Stop'
Import-Module DnsServer
$current = @((Get-DnsServerForwarder).IPAddress | ForEach-Object { "$_" })
if ($current -notcontains $Forwarder) {
    Set-DnsServerForwarder -IPAddress $Forwarder -UseRootHint $false
    "DNS forwarder set to $Forwarder (Azure DNS)."
} else {
    "DNS forwarder already $Forwarder."
}
Import-Module ActiveDirectory
$d = Get-ADDomain
"Domain $($d.DNSRoot) ($($d.NetBIOSName)) is answering. PDC: $($d.PDCEmulator)."
