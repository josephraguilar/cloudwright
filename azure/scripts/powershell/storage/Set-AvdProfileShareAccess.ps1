<#
.SYNOPSIS
    Finishes identity-based access on an FSLogix profile share for Entra-joined hosts.
.DESCRIPTION
    The Bicep module avd-profile-storage.bicep creates the account and share with
    Microsoft Entra Kerberos enabled and a default share-level permission. This script
    does the parts Bicep cannot, and is safe to run on an account that was set up in the
    portal instead:

      1. Verify (or enable) Entra Kerberos and the default share-level permission
      2. Optional RBAC on the share for a user group and an admin group
      3. Optional NTFS permissions on the share root, the FSLogix recommended set
      4. Print the admin-consent step, which has to be done once in the Entra portal

    Idempotent. Re-run after adding a group or when NTFS looks wrong.
.PARAMETER SubscriptionId
    Subscription containing the storage account.
.PARAMETER ResourceGroupName
    Resource group of the storage account.
.PARAMETER StorageAccountName
    Storage account name.
.PARAMETER ShareName
    File share name. Default profiles.
.PARAMETER DefaultSharePermission
    Share-level permission for all authenticated identities. Default
    StorageFileDataSmbShareContributor, which is what the portal recommends for FSLogix.
    Pass None to rely only on group RBAC.
.PARAMETER UserGroupObjectId
    Entra group to grant Storage File Data SMB Share Contributor on the share. Only needed
    when DefaultSharePermission is None, or for an explicit allow-list.
.PARAMETER AdminGroupObjectId
    Entra group to grant Storage File Data SMB Share Elevated Contributor (can change NTFS ACLs).
.PARAMETER SetNtfsPermissions
    Apply the FSLogix NTFS set to the share root. Where it runs depends on -NtfsVia.
.PARAMETER NtfsVia
    SessionHost (default): run the ACL step inside an existing session host through Run
    Command. Works regardless of your ISP. Needs -ViaVMName.
    Local: mount from this machine with the account key. Windows only, needs outbound
    TCP 445, which most ISPs block (errors 53, 67, 87).
.PARAMETER ViaVMName
    Session host VM to run the NTFS step on when -NtfsVia SessionHost.
.PARAMETER ViaVMResourceGroupName
    Resource group of that VM. Defaults to -ResourceGroupName.
.EXAMPLE
    ./Set-AvdProfileShareAccess.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab `
        -StorageAccountName stavdlabprofiles001 -ShareName profiles -SetNtfsPermissions -Verbose
.NOTES
    Requires: Az.Accounts, Az.Storage, Az.Resources
    Status:   Tested 2026-10-17 (Entra Kerberos and share permission; NTFS and automatic consent not yet)
    Roles:    Contributor on the storage account. User Access Administrator on it if
              assigning groups. The account key is read for the NTFS step.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   The account and share, plus the three optional things to do to them.
#   WHY    Mirrors the portal blade: Step 1 identity source, Step 2 share-level
#          permissions, Step 3 file and directory permissions.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter()]
    [string]$ShareName = 'profiles',

    [Parameter()]
    [ValidateSet('StorageFileDataSmbShareContributor', 'StorageFileDataSmbShareReader', 'StorageFileDataSmbShareElevatedContributor', 'None')]
    [string]$DefaultSharePermission = 'StorageFileDataSmbShareContributor',

    [Parameter()]
    [string]$UserGroupObjectId,

    [Parameter()]
    [string]$AdminGroupObjectId,

    [Parameter()]
    [switch]$SetNtfsPermissions,

    [Parameter()]
    [ValidateSet('SessionHost', 'Local')]
    [string]$NtfsVia = 'SessionHost',

    [Parameter()]
    [string]$ViaVMName,

    [Parameter()]
    [string]$ViaVMResourceGroupName
)
#endregion

#region 2. Setup --------------------------------------------------------------
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId

if ($SetNtfsPermissions -and $NtfsVia -eq 'SessionHost' -and -not $ViaVMName) {
    throw '-NtfsVia SessionHost needs -ViaVMName (a session host in the VNet). Or use -NtfsVia Local.'
}
if (-not $ViaVMResourceGroupName) { $ViaVMResourceGroupName = $ResourceGroupName }

$sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$shareScope = "$($sa.Id)/fileServices/default/fileshares/$ShareName"
$uncPath = "\\$StorageAccountName.file.core.windows.net\$ShareName"
#endregion

#region 3. Identity source and default permission ----------------------------
#   WHAT   Make sure Entra Kerberos is the identity source and the default share
#          permission matches. Portal "Step 1" and "Step 2".
#   WHY    Entra Kerberos lets an Entra-joined host get a Kerberos ticket for the
#          storage account from Entra ID, with no domain controller involved.
#          The default share permission is the coarse gate: any authenticated user
#          can reach the share, and NTFS decides what they can do inside it.
#   GOTCHA Enabling Entra Kerberos creates an app registration named
#          "[Storage Account] <name>.file.core.windows.net" in your tenant. That app
#          needs admin consent once (region 6 prints the steps). Until consent is
#          granted, mounts fail with a Kerberos error that looks like a permissions
#          problem.
$auth = $sa.AzureFilesIdentityBasedAuth
$currentSource = if ($auth) { $auth.DirectoryServiceOptions } else { 'None' }
$currentDefault = if ($auth -and $auth.DefaultSharePermission) { $auth.DefaultSharePermission } else { 'None' }

if ($currentSource -ne 'AADKERB') {
    if ($PSCmdlet.ShouldProcess($StorageAccountName, "Enable Microsoft Entra Kerberos (currently $currentSource)")) {
        Write-Verbose "Enabling Entra Kerberos on $StorageAccountName."
        $sa = Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableAzureActiveDirectoryKerberosForFile $true
    }
} else {
    Write-Verbose 'Entra Kerberos already enabled.'
}

if ($currentDefault -ne $DefaultSharePermission) {
    if ($PSCmdlet.ShouldProcess($StorageAccountName, "Set default share-level permission to $DefaultSharePermission (currently $currentDefault)")) {
        Write-Verbose "Setting default share permission to $DefaultSharePermission."
        $sa = Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -DefaultSharePermission $DefaultSharePermission
    }
} else {
    Write-Verbose "Default share permission already $DefaultSharePermission."
}
#endregion

#region 4. Group RBAC on the share (optional) --------------------------------
#   WHAT   Role assignments scoped to the share itself, not the whole account.
#   WHY    With a default share permission you do not strictly need these. Use them
#          when you set the default to None and want an explicit allow-list, or to
#          give admins the Elevated role so they can fix NTFS from a host.
function Grant-ShareRole {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ObjectId, [string]$Role, [string]$Scope, [string]$ShareName)
    $existing = Get-AzRoleAssignment -ObjectId $ObjectId -Scope $Scope -RoleDefinitionName $Role -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "'$Role' already assigned to $ObjectId on $ShareName."
        return
    }
    if ($PSCmdlet.ShouldProcess("$ObjectId on share $ShareName", "Assign '$Role'")) {
        Write-Verbose "Assigning '$Role' to $ObjectId on $ShareName."
        $null = New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $Role -Scope $Scope
    }
}
if ($UserGroupObjectId)  { Grant-ShareRole -ObjectId $UserGroupObjectId  -Role 'Storage File Data SMB Share Contributor'          -Scope $shareScope -ShareName $ShareName }
if ($AdminGroupObjectId) { Grant-ShareRole -ObjectId $AdminGroupObjectId -Role 'Storage File Data SMB Share Elevated Contributor' -Scope $shareScope -ShareName $ShareName }
#endregion

#region 5. NTFS permissions (optional) ---------------------------------------
#   WHAT   Apply the FSLogix recommended ACL to the share root. Portal "Step 3".
#          Either from inside a session host (Run Command) or from this machine.
#   WHY    Share-level RBAC says who may connect. NTFS says what they can do once
#          connected. FSLogix needs each user to create their own folder and then
#          own it, and nothing else: Authenticated Users get Modify on the root
#          folder only (not subfolders), CREATOR OWNER gets Modify on what they
#          create, Administrators get Full Control everywhere.
#   GOTCHA The key mount bypasses identity auth, which is the only way to set ACLs
#          before any identity has access. From a workstation it needs TCP 445
#          outbound, which most ISPs block (errors 53, 67, 87). A session host is
#          inside the VNet and reaches the storage account over the Azure backbone,
#          which is why SessionHost is the default.
if ($SetNtfsPermissions -and $NtfsVia -eq 'SessionHost') {
    $null = Set-AvdProfileShareAcl -ResourceGroupName $ViaVMResourceGroupName -VMName $ViaVMName `
        -StorageAccountName $StorageAccountName -StorageAccountResourceGroupName $ResourceGroupName -ShareName $ShareName `
        -Verbose:($VerbosePreference -eq 'Continue')
}
if ($SetNtfsPermissions -and $NtfsVia -eq 'Local') {
    if (-not $IsWindows) {
        throw 'NTFS permissions can only be set from Windows (needs net use and icacls).'
    }
    if ($PSCmdlet.ShouldProcess($uncPath, 'Apply FSLogix NTFS permissions to the share root')) {
        $key = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)[0].Value
        $drive = 'Z:'
        Write-Verbose "Mounting $uncPath as $drive with the account key."
        $null = net use $drive $uncPath /user:"Azure\$StorageAccountName" $key /persistent:no
        if ($LASTEXITCODE -ne 0) {
            throw "net use failed (exit $LASTEXITCODE). Most likely TCP 445 outbound is blocked by your ISP. Check with: Test-NetConnection $StorageAccountName.file.core.windows.net -Port 445. Use -NtfsVia SessionHost instead."
        }

        try {
            # S-1-5-11 Authenticated Users, S-1-3-0 CREATOR OWNER, S-1-5-32-544 Administrators
            $acl = @(
                '/inheritance:r'
                '/grant', '*S-1-5-32-544:(OI)(CI)(F)'
                '/grant', '*S-1-5-11:(M)'
                '/grant', '*S-1-3-0:(OI)(CI)(IO)(M)'
            )
            Write-Verbose "Applying ACL: icacls $drive\ $($acl -join ' ')"
            $null = icacls "$drive\" @acl
            if ($LASTEXITCODE -ne 0) { throw "icacls failed (exit $LASTEXITCODE)." }
            Write-Verbose 'NTFS permissions applied.'
        } finally {
            $null = net use $drive /delete /y
        }
    }
}
#endregion

#region 6. Admin consent --------------------------------------------------------
#   WHAT   Grant admin consent to the storage account's Entra Kerberos service
#          principal through Microsoft Graph. Falls back to printing the portal steps.
#   WHY    This used to be the one manual click. It is a single Graph object (an
#          oauth2PermissionGrant for openid profile User.Read, all principals), and a
#          Global Administrator can create it from here. Nerdio cannot because it
#          runs as a managed identity with no directory role; a person can.
$consent = $null
try {
    $consent = Grant-AvdStorageKerberosConsent -StorageAccountName $StorageAccountName -Verbose:($VerbosePreference -eq 'Continue')
    if ($consent) { Write-Verbose "Admin consent: $consent." }
} catch {
    Write-Warning "Automatic admin consent failed: $($_.Exception.Message)"
    Write-Warning @"
Grant it in the portal instead (once per storage account):
  Entra admin center > App registrations > All applications
  > search "[Storage Account] $StorageAccountName.file.core.windows.net"
  > API permissions > Grant admin consent for <tenant>
Until then, Entra-joined hosts cannot mount $uncPath.
"@
}

$sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
[pscustomobject]@{
    StorageAccount         = $StorageAccountName
    Share                  = $ShareName
    UncPath                = $uncPath
    IdentitySource         = $sa.AzureFilesIdentityBasedAuth.DirectoryServiceOptions
    DefaultSharePermission = $sa.AzureFilesIdentityBasedAuth.DefaultSharePermission
    NtfsApplied            = [bool]$SetNtfsPermissions
    NtfsVia                = if ($SetNtfsPermissions) { $NtfsVia } else { $null }
    AdminConsent           = if ($consent) { $consent } else { 'Manual step required' }
}
#endregion
