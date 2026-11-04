<#
.SYNOPSIS
    Configures FSLogix profile container registry settings. Runs ON the session host.
.DESCRIPTION
    Invoked by New-AvdSessionHost.ps1 through Invoke-AzVMRunCommand, which copies this
    file to the VM and runs it as SYSTEM. It only writes registry values. FSLogix itself
    must already be installed (it is, on the Microsoft AVD marketplace images).
.PARAMETER ProfileShare
    UNC path of the profile share, e.g. \\stavdprofiles.file.core.windows.net\profiles
.PARAMETER SizeInMBs
    Maximum profile VHDX size. Default 30000 (about 30 GB). Dynamic, so it only
    consumes what is used.
.PARAMETER EntraKerberos
    1 on Entra-joined hosts using Azure Files with Microsoft Entra Kerberos. Adds the
    two registry values Windows needs to fetch a Kerberos ticket from Entra ID for
    the storage account. 0 (default) for AD-joined hosts. An int, not a switch,
    because Run Command passes parameters as plain strings.
.NOTES
    Status: Untested
    This file is not meant to be run from your workstation.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Run Command passes these as -Parameter @{ ProfileShare = ... }.
#   WHY    Keeping this a normal param block means you can also run it by hand on a
#          host while troubleshooting.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProfileShare,

    [Parameter()]
    [int]$SizeInMBs = 30000,

    [Parameter()]
    [int]$EntraKerberos = 0
)
#endregion

#region 2. Registry -----------------------------------------------------------
#   WHAT   The minimum FSLogix Profiles keys for a pooled host.
#   WHY    Enabled turns it on. VHDLocations is where profiles live (REG_MULTI_SZ, so
#          it can hold more than one path). DeleteLocalProfileWhenVHDShouldApply
#          prevents a stale local profile from blocking the container. FlipFlop puts
#          the username first in the folder name so the share is browsable.
#   GOTCHA These keys are read at logon. Changing them does not affect a user who is
#          already signed in.
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

$key = 'HKLM:\SOFTWARE\FSLogix\Profiles'
$null = New-Item -Path $key -Force

$values = @(
    @{ Name = 'Enabled';                              Type = 'DWord';       Value = 1 }
    @{ Name = 'VHDLocations';                         Type = 'MultiString'; Value = @($ProfileShare) }
    @{ Name = 'VolumeType';                           Type = 'String';      Value = 'VHDX' }
    @{ Name = 'SizeInMBs';                            Type = 'DWord';       Value = $SizeInMBs }
    @{ Name = 'IsDynamic';                            Type = 'DWord';       Value = 1 }
    @{ Name = 'FlipFlopProfileDirectoryName';         Type = 'DWord';       Value = 1 }
    @{ Name = 'DeleteLocalProfileWhenVHDShouldApply'; Type = 'DWord';       Value = 1 }
    @{ Name = 'LockedRetryCount';                     Type = 'DWord';       Value = 3 }
    @{ Name = 'LockedRetryInterval';                  Type = 'DWord';       Value = 15 }
)
foreach ($v in $values) {
    $null = New-ItemProperty -Path $key -Name $v.Name -PropertyType $v.Type -Value $v.Value -Force
}
#endregion

#region 3. Entra Kerberos (optional) -----------------------------------------
#   WHAT   Two values that let an Entra-joined host authenticate to Azure Files.
#   WHY    CloudKerberosTicketRetrievalEnabled tells Windows it may ask Entra ID for
#          Kerberos tickets. LoadCredKeyFromProfile makes the credential key load
#          from the FSLogix profile at sign-in so the ticket is usable before the
#          profile is mounted. Without both, the share mounts for an admin by hand
#          but FSLogix fails at logon with "access denied".
#   GOTCHA These are the same values Microsoft's "Configure a profile container with
#          Azure Files and Microsoft Entra ID" guide sets with Intune. Doing it here
#          means no Intune dependency for a lab.
if ($EntraKerberos -eq 1) {
    $kerb = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'
    $null = New-Item -Path $kerb -Force
    $null = New-ItemProperty -Path $kerb -Name 'CloudKerberosTicketRetrievalEnabled' -PropertyType DWord -Value 1 -Force

    $aad = 'HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount'
    $null = New-Item -Path $aad -Force
    $null = New-ItemProperty -Path $aad -Name 'LoadCredKeyFromProfile' -PropertyType DWord -Value 1 -Force
}
#endregion

#region 4. Output -------------------------------------------------------------
#   WHAT   Echo what was written. Run Command returns stdout to the caller.
#   WHY    New-AvdSessionHost.ps1 writes this to its verbose stream so you can see
#          the host-side result without RDPing in.
Get-ItemProperty -Path $key | Select-Object Enabled, VHDLocations, VolumeType, SizeInMBs, IsDynamic
if ($EntraKerberos -eq 1) { "EntraKerberos: CloudKerberosTicketRetrievalEnabled=1 LoadCredKeyFromProfile=1" }
#endregion
