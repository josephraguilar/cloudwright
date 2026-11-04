#region Module setup ----------------------------------------------------------
#   WHAT   Storage accounts and their file shares: list with usage, create an
#          account (secure defaults), create a share, change a share's quota.
#   WHY    Profile shares fill up quietly; a list with used against quota is the
#          early warning, and a quota change is the fix that needs no downtime.
#   GOTCHA A quota can grow freely but never drops below what is stored. Premium
#          shares bill for the quota, not the usage, and start at 100 GiB.
#          Nothing here deletes an account, a share or a file.
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
#endregion

#region Lookups ---------------------------------------------------------------
function Get-FilesAccountInfo {
    <#
    .SYNOPSIS
        Storage accounts that can hold file shares, as flat rows.
    #>
    [CmdletBinding()]
    param([Parameter()] [string]$ResourceGroupName)
    $accounts = if ($ResourceGroupName) { @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName) } else { @(Get-AzStorageAccount) }
    foreach ($a in $accounts | Where-Object { "$($_.Kind)" -in 'StorageV2', 'FileStorage', 'Storage' } | Sort-Object ResourceGroupName, StorageAccountName) {
        $auth = if ($a.AzureFilesIdentityBasedAuth) { "$($a.AzureFilesIdentityBasedAuth.DirectoryServiceOptions)" } else { 'None' }
        [pscustomobject]@{
            Name              = $a.StorageAccountName
            ResourceGroupName = $a.ResourceGroupName
            Location          = $a.PrimaryLocation
            Kind              = "$($a.Kind)"
            Sku               = "$($a.Sku.Name)"
            IdentityAuth      = $(if ($auth -eq 'AADKERB') { 'Entra Kerberos' } elseif ($auth -eq 'AD') { 'AD DS' } elseif ($auth -eq 'AADDS') { 'Entra Domain Services' } else { $auth })
            PublicAccess      = "$($a.PublicNetworkAccess)"
            MinTls            = "$($a.MinimumTlsVersion)"
            Id                = $a.Id
        }
    }
}

function Get-FilesShareInfo {
    <#
    .SYNOPSIS
        Shares of one account with quota, usage and the UNC path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$StorageAccountName
    )
    foreach ($s in @(Get-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName) | Sort-Object Name) {
        $u = Get-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $s.Name -GetShareUsage -ErrorAction SilentlyContinue
        $usedGiB = if ($u -and $u.ShareUsageBytes) { [math]::Round($u.ShareUsageBytes / 1GB, 1) } else { 0 }
        $quota = [int]$s.QuotaGiB
        [pscustomobject]@{
            Name       = $s.Name
            QuotaGiB   = $quota
            UsedGiB    = $usedGiB
            PercentUsed = $(if ($quota -gt 0) { [math]::Round(100 * $usedGiB / $quota, 0) } else { 0 })
            Tier       = "$($s.AccessTier)"
            Protocol   = "$($s.EnabledProtocols)"
            Unc        = "\\$StorageAccountName.file.core.windows.net\$($s.Name)"
            Account    = $StorageAccountName
            ResourceGroupName = $ResourceGroupName
        }
    }
}

function Test-FilesAccountName {
    <#
    .SYNOPSIS
        True for 3 to 24 lower-case letters and digits (the storage account rule).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Name)
    return ($Name -cmatch '^[a-z0-9]{3,24}$')
}
#endregion

#region Create and change -----------------------------------------------------
function New-FilesStorageAccount {
    <#
    .SYNOPSIS
        A storage account for file shares: HTTPS only, TLS 1.2, no anonymous blob
        access. Premium is FileStorage (SSD, quota-billed); Standard is StorageV2
        with large file shares. Returns the existing one if the name is taken here.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [ValidateSet('Premium', 'Standard')] [string]$Performance = 'Premium',
        [Parameter()] [ValidateSet('LRS', 'ZRS')] [string]$Redundancy = 'LRS'
    )
    if (-not (Test-FilesAccountName $Name)) { throw "Storage account name '$Name' must be 3 to 24 lower-case letters and digits." }
    $existing = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "Storage account $Name exists."; return $existing }
    $avail = Get-AzStorageAccountNameAvailability -Name $Name
    if (-not $avail.NameAvailable) { throw "Storage account name '$Name' is taken: $($avail.Message)" }
    $p = @{
        ResourceGroupName = $ResourceGroupName; Name = $Name; Location = $Location
        MinimumTlsVersion = 'TLS1_2'; AllowBlobPublicAccess = $false; EnableHttpsTrafficOnly = $true
    }
    if ($Performance -eq 'Premium') { $p.Kind = 'FileStorage'; $p.SkuName = "Premium_$Redundancy" }
    else { $p.Kind = 'StorageV2'; $p.SkuName = "Standard_$Redundancy"; $p.EnableLargeFileShare = $true }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create $($p.SkuName) $($p.Kind) storage account")) { return }
    Write-Verbose "Creating storage account $Name ($($p.SkuName))."
    return New-AzStorageAccount @p
}

function New-FilesShare {
    <#
    .SYNOPSIS
        A file share with a quota. Returns the existing one untouched if the name is taken.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$StorageAccountName,
        [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9](?!.*--)[a-z0-9-]{1,61}[a-z0-9]$')] [string]$Name,
        [Parameter()] [ValidateRange(1, 102400)] [int]$QuotaGiB = 100,
        [Parameter()] [ValidateSet('', 'TransactionOptimized', 'Hot', 'Cool')] [string]$AccessTier = ''
    )
    $existing = Get-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "Share $Name exists ($($existing.QuotaGiB) GiB)."; return $existing }
    $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    $premium = "$($sa.Sku.Name)" -like 'Premium*'
    if ($premium -and $QuotaGiB -lt 100) { throw 'Premium file shares start at 100 GiB.' }
    if (-not $PSCmdlet.ShouldProcess("$StorageAccountName/$Name", "Create file share ($QuotaGiB GiB)")) { return }
    $p = @{ ResourceGroupName = $ResourceGroupName; StorageAccountName = $StorageAccountName; Name = $Name; QuotaGiB = $QuotaGiB }
    if ($AccessTier -and -not $premium) { $p.AccessTier = $AccessTier }
    Write-Verbose "Creating share $Name on $StorageAccountName."
    return New-AzRmStorageShare @p
}

function Set-FilesShareQuota {
    <#
    .SYNOPSIS
        Change a share's quota. Refuses a quota below what is stored, and below
        100 GiB on premium.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$StorageAccountName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateRange(1, 102400)] [int]$QuotaGiB
    )
    $s = Get-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $Name -GetShareUsage
    $usedGiB = [math]::Ceiling([double]$s.ShareUsageBytes / 1GB)
    if ($QuotaGiB -lt $usedGiB) { throw "$Name holds $usedGiB GiB; the quota cannot go below that." }
    $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    if ("$($sa.Sku.Name)" -like 'Premium*' -and $QuotaGiB -lt 100) { throw 'Premium file shares need at least 100 GiB.' }
    if ($QuotaGiB -eq [int]$s.QuotaGiB) { Write-Verbose "$Name is already $QuotaGiB GiB."; return $s }
    if (-not $PSCmdlet.ShouldProcess("$StorageAccountName/$Name", "Quota $($s.QuotaGiB) -> $QuotaGiB GiB")) { return }
    Write-Verbose "Setting $Name quota to $QuotaGiB GiB (was $($s.QuotaGiB))."
    return Update-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $Name -QuotaGiB $QuotaGiB
}
#endregion
