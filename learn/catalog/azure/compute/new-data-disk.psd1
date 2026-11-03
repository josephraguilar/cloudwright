@{
    Id      = 'azure.compute.new-data-disk'
    Title   = 'Add an empty data disk to a VM'
    Summary = 'Creates a managed disk and attaches it at a LUN. You still initialise and format it inside the OS.'
    Learn   = @(
        'CreateOption Empty makes the disk as part of the attach. To attach an existing disk use CreateOption Attach with -ManagedDiskId.'
        'LUN is just a slot number per VM; start at 0 and count up. The OS sees it as a new raw disk.'
        'Premium_LRS needs an s-series VM size (Standard_D4s_v5, not Standard_D4_v5).'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute'); Roles = @('Virtual Machine Contributor on the VM') }
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'Virtual machine'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVM'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'DiskName'; Label = 'Disk name'; Help = 'The managed disk resource name.'; Type = 'String'; Required = $true; Example = 'vm-data-01' }
        @{ Name = 'SizeGb'; Label = 'Size in GB'; Help = 'Disk size in GB. You can grow a disk later, never shrink it.'; Type = 'Int'; Required = $true; Default = '128' }
        @{ Name = 'Sku'; Label = 'Disk type'; Help = 'Disk type. Premium_LRS = SSD with guaranteed IOPS, needs a VM size with an s in it (Standard_D4s_v5). StandardSSD_LRS = SSD without guarantees, fine for most workloads. Standard_LRS = HDD, cheapest, for cold data. Premium_ZRS = premium replicated across 3 zones so the disk survives a zone outage. LRS/ZRS is how many datacentres hold a copy.'; Type = 'Choice'; Required = $true; Default = 'Premium_LRS'; Options = @('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS', 'Premium_ZRS') }
        @{ Name = 'Lun'; Label = 'LUN (0 for the first data disk)'; Help = 'Logical Unit Number: the slot on the virtual SCSI controller the disk appears in. It has to be unique per VM and is what the guest OS uses to tell data disks apart. Start at 0 and count up; the number has no other meaning.'; Type = 'Int'; Required = $true; Default = '0' }
    )
    Steps = @(
        @{
            Title = 'Create and attach the disk'
            What  = 'Adds an empty data disk to the VM model and updates the VM, which creates and attaches the disk.'
            Why   = 'No reboot for a data disk attach on a running VM.'
            Fixed = @('CreateOption')
            Raw   = @('Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} | Add-AzVMDataDisk -Name {{DiskName}} -CreateOption Empty -DiskSizeInGB {{SizeGb}} -Lun {{Lun}} -StorageAccountType {{Sku}} | Update-AzVM -ResourceGroupName {{ResourceGroupName}}')
        }
    )
    Verify   = @('(Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}}).StorageProfile.DataDisks | Format-Table Name, Lun, DiskSizeGB, @{ n = ''Type''; e = { $_.ManagedDisk.StorageAccountType } }')
    Rollback = @(
        'Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} | Remove-AzVMDataDisk -Name {{DiskName}} | Update-AzVM -ResourceGroupName {{ResourceGroupName}}    # Detach'
        'Remove-AzDisk -ResourceGroupName {{ResourceGroupName}} -DiskName {{DiskName}} -Force    # Then delete. Data is gone.'
    )
    Docs     = @('https://learn.microsoft.com/powershell/module/az.compute/add-azvmdatadisk')
    Status   = 'Untested'
}
