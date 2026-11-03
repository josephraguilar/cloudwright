@{
    Id      = 'azure.compute.restart-vm'
    Title   = 'Restart a virtual machine'
    Summary = 'Reboots the VM in place. Keeps IPs and the hardware reservation.'
    Learn   = @(
        'Equivalent to a reboot from the OS, triggered through the control plane. Use it when the OS is unresponsive.'
        'For a host-level redeploy to new hardware use Set-AzVM -Redeploy instead.'
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
            Title      = 'Restart a virtual machine'
            What       = 'Reboots the VM in place. Keeps IPs and the hardware reservation.'
            Why        = 'Control-plane operation; no sign-in to the OS needed.'
            Cmdlet     = 'Restart-AzVM'
            Parameters = @{ Name = '{{VMName}}'; ResourceGroupName = '{{ResourceGroupName}}' }
        }
    )
    Verify   = @('Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} -Status | Select-Object Name, @{ n = ''Power''; e = { $_.Statuses[-1].DisplayStatus } }')

    Docs     = @('https://learn.microsoft.com/powershell/module/az.compute/restart-azvm')
    Status   = 'Untested'
}
