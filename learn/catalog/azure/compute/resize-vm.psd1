@{
    Id      = 'azure.compute.resize-vm'
    Title   = 'Resize a virtual machine'
    Summary = 'Changes the VM size. The VM reboots. If the new size is not available on the current hardware cluster, deallocate first.'
    Learn   = @(
        'Get-AzVMSize -ResourceGroupName -VMName lists only the sizes the VM can move to without deallocating. If yours is missing, Stop-AzVM first, then any size in the region works.'
        'Size changes keep disks and IPs. Temp disk contents are lost.'
        'The size is a property on the VM model; you set it and push the whole model back with Update-AzVM.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute'); Roles = @('Virtual Machine Contributor on the VM') }
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'Virtual machine'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVM'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'NewSize'; Label = 'New size (list shows sizes available without deallocating)'; Help = 'The target VM size. The list shows only sizes available without deallocating.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVMSize'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; VMName = '{{VMName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title = 'Set the size and update the VM'
            What  = 'Gets the VM model, changes HardwareProfile.VmSize, writes it back. The VM restarts.'
            Why   = 'There is no Set-AzVMSize; the size is part of the VM resource.'
            Raw   = @('Update-AzVM -ResourceGroupName {{ResourceGroupName}} -VM (Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} | ForEach-Object { $_.HardwareProfile.VmSize = {{NewSize}}; $_ })')
        }
    )
    Verify = @('Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, @{ n = ''Size''; e = { $_.HardwareProfile.VmSize } }')
    Docs   = @('https://learn.microsoft.com/powershell/module/az.compute/update-azvm', 'https://learn.microsoft.com/powershell/module/az.compute/get-azvmsize')
    Status = 'Untested'
}
