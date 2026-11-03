@{
    Id      = 'azure.compute.run-command'
    Title   = 'Run a PowerShell command inside a VM'
    Summary = 'Executes a script inside the guest OS as SYSTEM through the VM agent, no RDP or network path to the VM needed.'
    Learn   = @(
        'Run Command goes through the Azure VM agent, so it works with no public IP and no NSG rule. It needs the VM to be running and the agent healthy.'
        'Output is captured (first 4 KB or so). Long scripts should write to a file or log and you read that separately.'
        'It runs as SYSTEM. Anything you can do as local admin, this can do. Treat the right to run it (Microsoft.Compute/virtualMachines/runCommand/action) as admin access to the VM.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute'); Roles = @('Virtual Machine Contributor on the VM') }
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'Virtual machine'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVM'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'CommandId'; Label = 'Command type'; Help = 'Which Run Command handler the VM agent uses. RunPowerShellScript runs the text as PowerShell on a Windows guest; RunShellScript runs it as bash on Linux. Both execute as SYSTEM/root through the agent, so no network path to the VM is needed.'; Type = 'Choice'; Required = $true; Default = 'RunPowerShellScript'; Options = @(@{ Display = 'RunPowerShellScript (Windows)'; Value = 'RunPowerShellScript' }, @{ Display = 'RunShellScript (Linux)'; Value = 'RunShellScript' }) }
        @{ Name = 'Script'; Label = 'Script to run inside the VM'; Help = 'The script text to run inside the guest OS as SYSTEM through the VM agent.'; Type = 'String'; Required = $true; Default = 'hostname; whoami; Get-Service -Name RDAgent* | Select-Object Name, Status' }
    )
    Steps = @(
        @{
            Title      = 'Run the command'
            What       = 'Sends the script to the VM agent and waits for the result.'
            Why        = 'The generic post-build hook: FSLogix registry, agent checks, quick diagnostics.'
            Cmdlet     = 'Invoke-AzVMRunCommand'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; VMName = '{{VMName}}'; CommandId = '{{CommandId}}'; ScriptString = '{{Script}}' }
            ParameterOrder = @('ResourceGroupName', 'VMName', 'CommandId', 'ScriptString')
            WhatIf     = $false
        }
    )
    Docs   = @('https://learn.microsoft.com/powershell/module/az.compute/invoke-azvmruncommand')
    Status = 'Untested'
}
