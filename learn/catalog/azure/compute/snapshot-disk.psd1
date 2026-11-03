@{
    Id      = 'azure.compute.snapshot-disk'
    Title   = 'Snapshot a managed disk'
    Summary = 'A point-in-time copy of a disk, billed per GB used. Take one before risky changes; restore by creating a new disk from it.'
    Learn   = @(
        'Snapshots are crash-consistent, not application-consistent. For SQL or AD, quiesce first or use Azure Backup.'
        'Incremental snapshots (-Incremental) only store changed blocks after the first one and are cheaper. Not all disk types support them.'
        'A snapshot is its own resource. Deleting the VM or disk does not delete it.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute'); Roles = @('Contributor on the resource group') }
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'DiskName'; Label = 'Disk'; Help = 'The managed disk resource name.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzDisk'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SnapshotName'; Label = 'Snapshot name'; Help = 'The snapshot resource name. Include the disk name and a date.'; Type = 'String'; Required = $true; Example = 'vm-jump-01-osdisk-before-patch' }
        @{ Name = 'Location'; Label = 'Region (same as the disk)'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'Incremental'; Label = 'Incremental (cheaper; only changed blocks after the first)'; Help = 'An incremental snapshot stores only the blocks changed since the previous snapshot of the same disk, so a chain of daily snapshots costs a fraction of full copies. The first one is always full. Requires a managed disk and is the recommended type; restore works the same either way.'; Type = 'Bool'; Required = $false; Default = $true }
    )
    Steps = @(
        @{
            Title      = 'Describe the snapshot'
            What       = 'A snapshot config pointing at the disk: copy, in the same region, incremental if ticked.'
            Why        = 'Config object then create is the Az pattern for disks and snapshots.'
            Cmdlet     = 'New-AzSnapshotConfig'
            Parameters = @{ SourceUri = '(Get-AzDisk -ResourceGroupName {{ResourceGroupName}} -DiskName {{DiskName}}).Id'; Location = '{{Location}}'; CreateOption = '''Copy'''; Incremental = '{{Incremental}}' }
            ParameterOrder = @('SourceUri', 'Location', 'CreateOption', 'Incremental')
            Fixed      = @('CreateOption')
            Output     = 'snapshotConfig'
            WhatIf     = $false
        }
        @{
            Title      = 'Create the snapshot'
            What       = 'Creates the snapshot resource from the config.'
            Why        = 'Billed per GB used from this moment.'
            Cmdlet     = 'New-AzSnapshot'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; SnapshotName = '{{SnapshotName}}'; Snapshot = '$snapshotConfig' }
            ParameterOrder = @('ResourceGroupName', 'SnapshotName', 'Snapshot')
        }
    )
    Verify   = @('Get-AzSnapshot -ResourceGroupName {{ResourceGroupName}} -SnapshotName {{SnapshotName}} | Select-Object Name, DiskSizeGB, TimeCreated, Incremental')
    Rollback = @('Remove-AzSnapshot -ResourceGroupName {{ResourceGroupName}} -SnapshotName {{SnapshotName}} -Force')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.compute/new-azsnapshot')
    Status   = 'Untested'
}
