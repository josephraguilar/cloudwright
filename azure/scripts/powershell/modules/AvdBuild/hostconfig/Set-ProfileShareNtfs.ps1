<#
.SYNOPSIS
    Applies the FSLogix NTFS permission set to a profile share root. Runs ON a session host.
.DESCRIPTION
    Invoked by Set-AvdProfileShareAcl (AvdBuild) through Invoke-AzVMRunCommand. Mounts
    the share with the storage account key, applies ACLs with icacls, unmounts.
    Runs from inside the VNet, so it works even when the admin's ISP blocks port 445.
.PARAMETER ShareUnc
    \\<account>.file.core.windows.net\<share>
.PARAMETER UserName
    Azure\<account>
.PARAMETER Key
    Storage account key. Passed by Run Command; visible in the run's log on the VM.
    Rotate the key afterwards if that matters to you.
.NOTES
    Status: Untested
    Not meant to be run from your workstation.
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ShareUnc,
    [Parameter(Mandatory)] [string]$UserName,
    [Parameter(Mandatory)] [string]$Key
)
#endregion

#region 2. Mount, ACL, unmount ------------------------------------------------
#   WHAT   Same ACL set as the local path in Set-AvdProfileShareAccess.ps1.
#   WHY    Well-known SIDs so it works on any locale: S-1-5-32-544 Administrators,
#          S-1-5-11 Authenticated Users, S-1-3-0 CREATOR OWNER.
#          Users get Modify on the root only, CREATOR OWNER gets Modify on what they
#          create, Administrators get Full Control everywhere.
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

$drive = 'Y:'
$null = net use $drive $ShareUnc /user:$UserName $Key /persistent:no
if ($LASTEXITCODE -ne 0) { throw "net use failed (exit $LASTEXITCODE) mounting $ShareUnc" }
try {
    $acl = @('/inheritance:r', '/grant', '*S-1-5-32-544:(OI)(CI)(F)', '/grant', '*S-1-5-11:(M)', '/grant', '*S-1-3-0:(OI)(CI)(IO)(M)')
    $null = icacls "$drive\" @acl
    if ($LASTEXITCODE -ne 0) { throw "icacls failed (exit $LASTEXITCODE)" }
    "NTFS applied to $ShareUnc"
    icacls "$drive\"
} finally {
    $null = net use $drive /delete /y
}
#endregion
