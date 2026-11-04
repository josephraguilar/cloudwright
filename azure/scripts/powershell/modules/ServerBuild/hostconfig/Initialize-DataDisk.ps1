<#
.SYNOPSIS
    Runs INSIDE a VM: formats the raw data disk at a given LUN as one NTFS volume.
.NOTES
    The Azure temp disk (D:) is already formatted, so only RAW disks qualify. The
    LUN is read from the disk's Location string ("... LUN 0"). 64 KB allocation
    units suit SQL and AD database files. Idempotent: an existing drive letter
    means nothing is changed.
#>
param(
    [int]$Lun = 0,
    [string]$DriveLetter = 'F',
    [string]$Label = 'Data'
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

$ErrorActionPreference = 'Stop'
if (Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue) {
    "Drive ${DriveLetter}: already exists; nothing to do."
    return
}
$raw = @(Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' })
$disk = $raw | Where-Object { $_.Location -match "LUN\s+$Lun\b" } | Select-Object -First 1
if (-not $disk) { $disk = $raw | Sort-Object Number | Select-Object -First 1 }
if (-not $disk) { throw "No raw disk found to format as ${DriveLetter}: (LUN $Lun)." }
$null = Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
    New-Partition -DriveLetter $DriveLetter -UseMaximumSize |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel $Label -AllocationUnitSize 65536 -Confirm:$false
"Formatted disk $($disk.Number) ($([math]::Round($disk.Size / 1GB)) GB, $($disk.Location)) as ${DriveLetter}: '$Label'."
