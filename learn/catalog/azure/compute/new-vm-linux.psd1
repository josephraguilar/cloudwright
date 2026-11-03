@{
    Id      = 'azure.compute.new-vm-linux'
    Title   = 'Create a Linux virtual machine (SSH key)'
    Summary = 'One New-AzVM call for an Ubuntu or Debian VM that authenticates with an SSH public key, no password.'
    Learn   = @(
        'New-AzVM -SshKeyName uses an SSH public key resource already in Azure. -GenerateSshKey makes one for you and saves the private key under ~/.ssh.'
        'Password auth stays disabled when a key is given. That is the right default for anything internet-facing.'
        'Ubuntu2204 and Ubuntu2404 are image aliases. Pass a URN for anything else.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute', 'Az.Network'); Roles = @('Contributor on the resource group') }
    Prerequisites = @('azure.network.new-vnet')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'VM name'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'String'; Required = $true; Pattern = '^[A-Za-z0-9-]{1,64}$'; Example = 'vm-web-01' }
        @{ Name = 'VMSize'; Label = 'VM size'; Help = 'The VM SKU, read like Standard_D4s_v5: family D (general purpose; B = burstable/cheap, E = memory heavy, F = compute heavy, N = GPU), 4 vCPUs, s = supports premium SSD disks, v5 = hardware generation. Multi-session AVD hosts are usually D4s_v5 or D8s_v5 (4 to 8 vCPU, 16 to 32 GB). Pick an s size if you want premium disks. The list comes from Get-AzVMSize for the region.'; Type = 'Choice'; Required = $true; Default = 'Standard_B2s'
           Source = @{ Cmdlet = 'Get-AzVMSize'; Parameters = @{ Location = '{{Location}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'Image'; Label = 'Image'; Help = 'Which Linux distribution. These are Az aliases that resolve to the current marketplace image. For anything else pass a URN Publisher:Offer:SKU:Version (Get-AzVMImageSku lists them).'; Type = 'Choice'; Required = $true; Default = 'Ubuntu2404'; Options = @('Ubuntu2404', 'Ubuntu2204', 'Debian11', 'RHELRaw8LVMGen2') }
        @{ Name = 'AdminUser'; Label = 'Admin user name (password is ignored; SSH key is used)'; Help = 'Not entered here. Get-Credential prompts for the admin user name when the script runs; the password is ignored because an SSH key is used.'; Type = 'Secret' }
        @{ Name = 'SshKeyName'; Label = 'SSH key resource name'; Help = 'An Azure resource that holds an SSH public key, so several VMs can share it and the key outlives any one VM. The private key never leaves your machine.'; Type = 'String'; Required = $true; Example = 'sshkey-lab' }
        @{ Name = 'GenerateSshKey'; Label = 'Generate the key pair if the key resource does not exist'; Help = 'If the named SSH key resource does not exist, Az creates an RSA key pair, stores the public half in Azure, and writes the private key to ~/.ssh on the machine running the script. Keep that file; it is the only copy. If the resource already exists, this is ignored.'; Type = 'Bool'; Required = $false; Default = $true }
        @{ Name = 'VNetName'; Label = 'Virtual network'; Help = 'The virtual network. Subnets live inside it; NICs attach to subnets.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVirtualNetwork'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SubnetName'; Label = 'Subnet name'; Help = 'The subnet inside the VNet. NICs, VMs, and session hosts are placed in a subnet.'; Type = 'String'; Required = $true; Default = 'snet-hosts' }
        @{ Name = 'PipName'; Label = 'Public IP name (blank for none)'; Help = 'A public IP address is its own Azure resource that you attach to a NIC, load balancer, Bastion, or NAT gateway. Leave blank to keep the NIC private; you then reach the VM through Bastion, a VPN, or AVD.'; Type = 'String'; Required = $false }
        @{ Name = 'OpenPorts'; Label = 'Open inbound ports (blank for none)'; Help = 'Inbound TCP ports that New-AzVM writes as allow rules into the NSG it creates, open to the whole internet. 3389 (RDP) and 22 (SSH) exposed this way are the most common way VMs get compromised; prefer Azure Bastion or a VPN and leave this blank, or lock the rule to your IP afterwards.'; Type = 'MultiChoice'; Required = $false; Options = @('22', '443', '80') }
    )
    Steps = @(
        @{
            Title      = 'Create the VM with SSH key auth'
            What       = 'Creates the VM; generates and stores the SSH key pair if the key resource does not exist (private key saved locally by Az).'
            Why        = 'Keys, not passwords, for Linux.'
            Cmdlet     = 'New-AzVM'
            Parameters = @{
                Name = '{{VMName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}'
                Image = '{{Image}}'; Size = '{{VMSize}}'; Credential = '{{AdminUser}}'
                SshKeyName = '{{SshKeyName}}'; GenerateSshKey = '{{GenerateSshKey}}'
                VirtualNetworkName = '{{VNetName}}'; SubnetName = '{{SubnetName}}'; PublicIpAddressName = '{{PipName}}'; OpenPorts = '{{OpenPorts}}'
            }
            ParameterOrder = @('Name', 'ResourceGroupName', 'Location', 'Image', 'Size', 'Credential', 'SshKeyName', 'GenerateSshKey', 'VirtualNetworkName', 'SubnetName', 'PublicIpAddressName', 'OpenPorts')
            Gotcha     = 'New-AzVM still requires -Credential for the username even with SSH keys; the password in it is ignored when a key is supplied.'
        }
    )
    Verify   = @('Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} -Status | Select-Object Name, @{ n = ''Power''; e = { $_.Statuses[-1].DisplayStatus } }')
    Rollback = @('Remove-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} -Force')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.compute/new-azvm')
    Status   = 'Untested'
}
