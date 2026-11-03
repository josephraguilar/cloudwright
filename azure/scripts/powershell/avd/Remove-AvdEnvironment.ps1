<#
.SYNOPSIS
    Tears down an AVD lab: the resource group and the Entra ID leftovers that outlive it.
.DESCRIPTION
    Deleting a resource group removes every Azure resource in it and nothing else.
    Three things live in Entra ID and survive:

      - device records for the session host VMs (block the next build's Entra join)
      - the "[Storage Account] <name>.file.core.windows.net" app from Entra Kerberos
      - the user group (kept unless -RemoveUserGroupObjectId is given)

    This script records the VM and storage account names, deletes the resource group,
    then deletes those Entra objects. Built for a lab that is torn down to stop the
    meter and rebuilt later with the same names.
.PARAMETER SubscriptionId
    Subscription containing the resource group.
.PARAMETER ResourceGroupName
    The resource group to delete. Everything in it goes.
.PARAMETER VMName
    Session host VM names whose Entra device records to remove. Needed only when the
    resource group is already gone (deleted by hand), since the names cannot be read
    from it any more.
.PARAMETER StorageAccountName
    Storage account names whose Entra Kerberos apps to remove. Same reason.
.PARAMETER RemoveUserGroupObjectId
    Also delete this Entra group. Off by default: the group is usually worth keeping.
.PARAMETER Force
    Skip the confirmation prompt. -WhatIf still works.
.EXAMPLE
    ./Remove-AvdEnvironment.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -Verbose
.NOTES
    Requires: Az.Accounts, Az.Resources, Az.Compute, Az.Storage, Az.RecoveryServices
    Status:   Untested
    Roles:    Contributor (or Owner) on the resource group. Cloud Device Administrator
              or Global Administrator for the device records; Application Administrator
              or Global Administrator for the storage app.
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter()]
    [string[]]$VMName,

    [Parameter()]
    [string[]]$StorageAccountName,

    [Parameter()]
    [string]$RemoveUserGroupObjectId,

    [Parameter()]
    [switch]$Force
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Modules, context, and an inventory of what is about to go.
#   WHY    The Entra cleanup needs the VM and storage account names, and they are
#          gone once the group is. Capture first, delete second.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
$resources = if ($rg) { @(Get-AzResource -ResourceGroupName $ResourceGroupName) } else { @() }
$vmNames = @(@($resources | Where-Object ResourceType -eq 'Microsoft.Compute/virtualMachines' | ForEach-Object Name) + @($VMName) | Select-Object -Unique)
$saNames = @(@($resources | Where-Object ResourceType -eq 'Microsoft.Storage/storageAccounts' | ForEach-Object Name) + @($StorageAccountName) | Select-Object -Unique)
$vaults  = @($resources | Where-Object ResourceType -eq 'Microsoft.RecoveryServices/vaults' | ForEach-Object Name)

if ($rg) {
    Write-Verbose "Resource group $ResourceGroupName holds $($resources.Count) resource(s): $($vmNames.Count) VM(s), $($saNames.Count) storage account(s), $($vaults.Count) vault(s)."
} else {
    Write-Verbose "Resource group $ResourceGroupName does not exist. Only Entra cleanup will run, by name."
}
#endregion

#region 3. Resource group -----------------------------------------------------
#   WHAT   Delete the group. One call removes every Azure resource in it.
#   GOTCHA A Recovery Services vault with protected items refuses deletion and
#          fails the whole group delete. Disable protection on its items first
#          (Disable-AzRecoveryServicesBackupProtection -RemoveRecoveryPoints), wait
#          for soft-deleted items to clear, then re-run.
if ($rg) {
    if ($vaults.Count -gt 0) {
        Write-Warning "Vault(s) in this group: $($vaults -join ', '). The delete will fail if they still hold protected items."
    }
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Delete resource group and all $($resources.Count) resource(s) in it")) {
        Write-Verbose "Deleting resource group $ResourceGroupName. This takes a few minutes."
        $null = Remove-AzResourceGroup -Name $ResourceGroupName -Force
        Write-Verbose 'Resource group deleted.'
    }
}
#endregion

#region 4. Entra leftovers ----------------------------------------------------
#   WHAT   Device records for the VMs, the storage accounts' Kerberos apps, and
#          optionally the user group.
#   WHY    None of these are Azure resources. Left behind, the device record breaks
#          the next Entra join and the storage app can collide with a recreated
#          account. Failures here are warnings: the group is already gone.
$devicesRemoved = 0
foreach ($n in $vmNames) {
    try { $devicesRemoved += Remove-AvdEntraDevice -Name $n }
    catch { Write-Warning "Entra device record for ${n}: $($_.Exception.Message)" }
}
$appsRemoved = 0
foreach ($n in $saNames) {
    try { $appsRemoved += Remove-AvdStorageKerberosApp -StorageAccountName $n }
    catch { Write-Warning "Entra app for storage account ${n}: $($_.Exception.Message)" }
}
$groupRemoved = $false
if ($RemoveUserGroupObjectId) {
    if ($PSCmdlet.ShouldProcess("Entra group $RemoveUserGroupObjectId", 'Delete')) {
        Remove-AzADGroup -ObjectId $RemoveUserGroupObjectId
        $groupRemoved = $true
    }
}
#endregion

#region 5. Output -------------------------------------------------------------
[pscustomobject]@{
    ResourceGroup        = $ResourceGroupName
    ResourceGroupDeleted = [bool]$rg -and -not $WhatIfPreference
    ResourcesDeleted     = $resources.Count
    VmDeviceRecords      = $devicesRemoved
    StorageKerberosApps  = $appsRemoved
    UserGroupDeleted     = $groupRemoved
    LeftInEntra          = @(
        if (-not $RemoveUserGroupObjectId) { 'User group (kept on purpose)' }
        'Test users (kept on purpose)'
    )
}
#endregion
