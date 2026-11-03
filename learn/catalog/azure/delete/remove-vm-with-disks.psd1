@{
    Id      = 'azure.delete.remove-vm-with-disks'
    Title   = 'Delete a VM and its OS disk and NIC'
    Summary = 'Remove-AzVM leaves the OS disk, NIC, and public IP behind, still billing. This deletes the VM, then those leftovers by name.'
    Learn   = @(
        'The disk and NIC names are read from the VM before it is deleted, which is why the first command stores nothing and the others look them up inline. Copy the names from the Verify output if you want to double check.'
        'Data disks are not touched. Delete them separately once you are sure.'
        'This is the delete half of the azure repo''s Invoke-AvdHostReimage.ps1. For an AVD host, also Remove-AzWvdSessionHost so the pool forgets it.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute', 'Az.Network'); Roles = @('Contributor on the resource group') }
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'Virtual machine'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVM'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'OsDiskName'; Label = 'OS disk (pick the one named after the VM)'; Help = 'The OS disk left behind by Remove-AzVM, usually named after the VM.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzDisk'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'NicName'; Label = 'NIC'; Help = 'The network interface resource. A VM plugs into a NIC; the NIC sits in a subnet.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzNetworkInterface'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title      = 'Delete the VM'
            What       = 'Removes the compute resource. Disks and NIC remain.'
            Why        = 'Must go first; the disk and NIC cannot be deleted while attached.'
            Cmdlet     = 'Remove-AzVM'
            Parameters = @{ Name = '{{VMName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Force = '$true' }
            Fixed      = @('Force')
        }
        @{
            Title      = 'Delete the OS disk'
            What       = 'Removes the managed disk.'
            Why        = 'Disks bill whether or not a VM uses them.'
            Cmdlet     = 'Remove-AzDisk'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; DiskName = '{{OsDiskName}}'; Force = '$true' }
            ParameterOrder = @('ResourceGroupName', 'DiskName', 'Force')
            Fixed          = @('Force')
        }
        @{
            Title      = 'Delete the NIC'
            What       = 'Removes the network interface. A public IP attached to it is detached, not deleted.'
            Why        = 'Leftover NICs hold private IPs in the subnet.'
            Cmdlet     = 'Remove-AzNetworkInterface'
            Parameters = @{ Name = '{{NicName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Force = '$true' }
            Fixed      = @('Force')
        }
    )
    Verify = @('Get-AzResource -ResourceGroupName {{ResourceGroupName}} | Where-Object Name -like "{{VMName:raw}}*" | Format-Table Name, ResourceType')
    Docs   = @('https://learn.microsoft.com/powershell/module/az.compute/remove-azvm')
    Status = 'Untested'
}
