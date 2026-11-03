@{
    Id      = 'azure.compute.start-vm'
    Title   = 'Start a virtual machine'
    Summary = 'Powers on a deallocated or stopped VM. Billing for compute starts again.'
    Learn   = @(
        'A deallocated VM gets a new dynamic private IP unless the NIC was set to static, and a new public IP unless the IP is static.'
        '-NoWait returns immediately; without it the cmdlet blocks until the VM reports running.'
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
            Title      = 'Start a virtual machine'
            What       = 'Powers on a deallocated or stopped VM. Billing for compute starts again.'
            Why        = 'Control-plane operation; no sign-in to the OS needed.'
            Cmdlet     = 'Start-AzVM'
            Parameters = @{ Name = '{{VMName}}'; ResourceGroupName = '{{ResourceGroupName}}' }
        }
    )
    Verify   = @('Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} -Status | Select-Object Name, @{ n = ''Power''; e = { $_.Statuses[-1].DisplayStatus } }')
    Rollback = @('Stop-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} -Force')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.compute/start-azvm')
    Status   = 'Untested'
}
