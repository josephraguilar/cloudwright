@{
    Id      = 'azure.compute.stop-vm'
    Title   = 'Stop (deallocate) a virtual machine'
    Summary = 'Shuts the VM down and releases the hardware so compute billing stops. Disks and IPs stay.'
    Learn   = @(
        'Stop-AzVM deallocates by default. Add -StayProvisioned to only shut down the OS (still billed, keeps the dynamic IP).'
        'Shutting down from inside the OS does NOT deallocate. The portal shows it as Stopped and you keep paying.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute'); Roles = @('Virtual Machine Contributor on the VM') }
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'Virtual machine'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVM'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title      = 'Stop (deallocate) a virtual machine'
            What       = 'Shuts the VM down and releases the hardware so compute billing stops. Disks and IPs stay.'
            Why        = 'Control-plane operation; no sign-in to the OS needed.'
            Cmdlet     = 'Stop-AzVM'
            Parameters = @{ Name = '{{VMName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Force = '$true' }
            Fixed      = @('Force')
        }
    )
    Verify   = @('Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} -Status | Select-Object Name, @{ n = ''Power''; e = { $_.Statuses[-1].DisplayStatus } }')
    Rollback = @('Start-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}}')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.compute/stop-azvm')
    Status   = 'Untested'
}
