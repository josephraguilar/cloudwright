<#
.SYNOPSIS
    Open RDP to a VM from your current public IP for a set time, write a .rdp
    file, and optionally launch it. Works for servers and AVD session hosts.
.DESCRIPTION
    What Nerdio's "generate RDP" does: a Standard public IP is attached to the VM
    if it has none (created once as <vm>-jit-pip, reused after), and an NSG rule
    named jit-rdp-<vm> allows TCP 3389 from your IP to the VM's private IP, with
    the expiry written into the rule. The rule lives on the NIC's NSG, else the
    subnet's (scoped to this VM), else a NIC-level NSG is created.

    Closing is Revoke-ServerRdpAccess.ps1, which sets the rule to Deny. The GUI
    does that on a timer; from the command line, run it yourself or schedule it.
    Nothing is deleted: the rule and the public IP stay parked for next time, and
    a Standard public IP with a Deny rule accepts nothing.
.PARAMETER SubscriptionId
    Subscription containing the VM.
.PARAMETER ResourceGroupName
    Resource group of the VM.
.PARAMETER Name
    VM name.
.PARAMETER Minutes
    How long: 30, 60, 120, 240, 480, anything 5 to 1440. Default 60.
.PARAMETER SourceIp
    IP or CIDR to allow. Default: this machine's public IP, looked up online.
.PARAMETER OutFile
    Where to write the .rdp file. Default: Downloads\<vm>.rdp.
.PARAMETER UserName
    Pre-filled user name in the .rdp file.
.PARAMETER EntraAuth
    For Entra-joined machines: sign in with an Entra account.
.PARAMETER Launch
    Open the .rdp file with mstsc after writing it.
.EXAMPLE
    ./Grant-ServerRdpAccess.ps1 -SubscriptionId <sub> -ResourceGroupName rg-servers -Name web01 -Minutes 120 -Launch
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Network
    Status:   Untested
    Roles:    Network Contributor on the resource group (NSG, public IP, NIC).
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter()] [ValidateRange(5, 1440)] [int]$Minutes = 60,
    [Parameter()] [string]$SourceIp,
    [Parameter()] [string]$OutFile,
    [Parameter()] [string]$UserName,
    [Parameter()] [switch]$EntraAuth,
    [Parameter()] [switch]$Launch
)
#endregion

#region 2. Setup --------------------------------------------------------------
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'ServerBuild' 'ServerBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$verbose = $VerbosePreference -eq 'Continue'
if (-not $OutFile) {
    $downloads = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    $OutFile = Join-Path $(if (Test-Path $downloads) { $downloads } else { [Environment]::GetFolderPath('UserProfile') }) "$Name.rdp"
}
#endregion

#region 3. Open, write, launch -----------------------------------------------
$p = @{ ResourceGroupName = $ResourceGroupName; Name = $Name; Minutes = $Minutes; Verbose = $verbose }
if ($SourceIp) { $p.SourceIp = $SourceIp }
$access = Grant-ServerRdpAccess @p
if (-not $access) { return }   # -WhatIf
$file = New-ServerRdpFile -Address $access.PublicIp -Port $access.Port -Path $OutFile -UserName $UserName -EntraAuth:$EntraAuth
if ($Launch -and -not $WhatIfPreference) {
    if (Get-Command mstsc.exe -ErrorAction SilentlyContinue) { Start-Process mstsc.exe -ArgumentList "`"$file`"" } else { Write-Warning 'mstsc.exe not found; open the .rdp file yourself.' }
}
[pscustomobject]@{
    VM = $Name; Address = "$($access.PublicIp):$($access.Port)"; From = $access.SourceIp
    OpenUntil = $access.ExpiresLocal.ToString('yyyy-MM-dd HH:mm'); RdpFile = $file
    CloseWith = "./Revoke-ServerRdpAccess.ps1 -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -Name $Name"
}
#endregion
