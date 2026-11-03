@{
    Id      = 'azure.inspect.vm-power-state'
    Title   = 'Show VM power states'
    Summary = 'Every VM with its power state (running, deallocated, stopped). Stopped still bills for compute; deallocated does not.'
    Learn   = @(
        'Get-AzVM without -Status returns the model only. -Status adds the instance view, which is where PowerState lives, at the cost of one extra call per VM.'
        '"VM stopped" means the OS shut down but the hardware is still reserved and billed. "VM deallocated" is what Stop-AzVM does by default.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute'); Roles = @('Reader') }
    Prerequisites = @('azure.context.set-subscription')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group (blank for the whole subscription)'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $false
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title      = 'List VMs with power state'
            What       = 'Lists VMs and their current power state.'
            Why        = 'The first question in any VM ticket.'
            Cmdlet     = 'Get-AzVM'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; Status = '$true' }
            Fixed      = @('Status')
            Output     = 'vms'
        }
        @{
            Title = 'Format the table'
            OnlyExplained = $true
            What  = 'Narrow to the columns that matter.'
            Why   = 'The default view hides PowerState.'
            Raw   = @('$vms | Select-Object Name, ResourceGroupName, Location, PowerState | Format-Table -AutoSize')
        }
    )
    Docs   = @('https://learn.microsoft.com/powershell/module/az.compute/get-azvm')
    Status = 'Untested'
}
