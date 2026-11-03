@{
    Id      = 'azure.compute.new-vm-windows'
    Title   = 'Create a Windows virtual machine'
    Summary = 'One New-AzVM call that creates the VM plus, if they do not exist, its NIC, NSG, and public IP. Good for a jump box or a lab server.'
    Learn   = @(
        'This is the simplified New-AzVM parameter set. It builds the NIC/NSG/public IP for you when you pass names that do not exist yet. The long form (New-AzVMConfig | Set-AzVM... | New-AzVM) is what the AVD session host task uses.'
        '-Image takes an alias (Win2022AzureEdition, Win2019Datacenter) or a URN Publisher:Offer:Sku:Version. latest resolves the newest at creation time.'
        'Trusted Launch is the default security type for Gen2 images. Pass Standard only for images that do not support it.'
        'The local admin credential is prompted when the script runs. It is never in this file.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute', 'Az.Network'); Roles = @('Contributor on the resource group') }
    Prerequisites = @('azure.network.new-vnet')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'VM name (1-15 chars, Windows computer name)'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'String'; Required = $true; Pattern = '^[A-Za-z0-9-]{1,15}$'; Example = 'vm-jump-01' }
        @{ Name = 'VMSize'; Label = 'VM size'; Help = 'The VM SKU, read like Standard_D4s_v5: family D (general purpose; B = burstable/cheap, E = memory heavy, F = compute heavy, N = GPU), 4 vCPUs, s = supports premium SSD disks, v5 = hardware generation. Multi-session AVD hosts are usually D4s_v5 or D8s_v5 (4 to 8 vCPU, 16 to 32 GB). Pick an s size if you want premium disks. The list comes from Get-AzVMSize for the region.'; Type = 'Choice'; Required = $true; Default = 'Standard_D2s_v5'
           Source = @{ Cmdlet = 'Get-AzVMSize'; Parameters = @{ Location = '{{Location}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'Image'; Label = 'Image'; Help = 'Which OS to install. An alias like Win2022AzureEdition is shorthand Az resolves for you. A URN is Publisher:Offer:SKU:Version, e.g. MicrosoftWindowsDesktop:office-365:win11-24h2-avd-m365:latest, where avd = multi-session (several users at once, AVD only), m365 = Microsoft 365 Apps preinstalled, latest = newest build at creation time. Browse with Get-AzVMImagePublisher / Offer / Sku.'; Type = 'Choice'; Required = $true; Default = 'Win2022AzureEdition'
           Options = @(
               @{ Display = 'Windows Server 2022 Azure Edition'; Value = 'Win2022AzureEdition' }
               @{ Display = 'Windows Server 2019 Datacenter';    Value = 'Win2019Datacenter' }
               @{ Display = 'Windows 11 24H2 Enterprise multi-session + M365 Apps (AVD)'; Value = 'MicrosoftWindowsDesktop:office-365:win11-24h2-avd-m365:latest' }
               @{ Display = 'Windows 11 24H2 Enterprise (single session)'; Value = 'MicrosoftWindowsDesktop:windows-11:win11-24h2-ent:latest' }
           ) }
        @{ Name = 'VNetName'; Label = 'Virtual network'; Help = 'The virtual network. Subnets live inside it; NICs attach to subnets.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVirtualNetwork'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SubnetName'; Label = 'Subnet name'; Help = 'The subnet inside the VNet. NICs, VMs, and session hosts are placed in a subnet.'; Type = 'String'; Required = $true; Default = 'snet-hosts' }
        @{ Name = 'NsgName'; Label = 'NSG name (existing, or a new one is created)'; Help = 'A Network Security Group is a stateful layer-4 firewall (IP, port, protocol) attached to a subnet or a NIC. New NSGs allow all traffic inside the VNet and all outbound, and block inbound from the internet, until you add rules. One per subnet is the usual design.'; Type = 'String'; Required = $false; Example = 'nsg-vm-jump' }
        @{ Name = 'PipName'; Label = 'Public IP name (blank for no public IP)'; Help = 'A public IP address is its own Azure resource that you attach to a NIC, load balancer, Bastion, or NAT gateway. Leave blank to keep the NIC private; you then reach the VM through Bastion, a VPN, or AVD.'; Type = 'String'; Required = $false; Example = 'pip-vm-jump' }
        @{ Name = 'OpenPorts'; Label = 'Open inbound ports on the new NSG (blank for none)'; Type = 'MultiChoice'; Required = $false; Options = @('3389', '443', '80'); Help = 'Inbound TCP ports that New-AzVM writes as allow rules into the NSG it creates, open to the whole internet. 3389 (RDP) and 22 (SSH) exposed this way are the most common way VMs get compromised; prefer Azure Bastion or a VPN and leave this blank, or lock the rule to your IP afterwards.' }
        @{ Name = 'LicenseType'; Label = 'Hybrid Benefit license'; Help = 'Azure Hybrid Benefit: tells Azure you already own the Windows licence so it stops charging for one. Windows_Client is for Windows 10/11 Enterprise multi-session, covered by Microsoft 365 E3/E5, Business Premium, or Windows E3/E5 per user. Windows_Server is for Windows Server with Software Assurance. None means pay-as-you-go. Setting it when you are not entitled is a licensing violation, not a technical error.'; Type = 'Choice'; Required = $false; Default = ''
           Options = @(@{ Display = 'None (pay as you go)'; Value = '' }, @{ Display = 'Windows_Server (Server with SA)'; Value = 'Windows_Server' }, @{ Display = 'Windows_Client (Win 10/11 multi-session via M365)'; Value = 'Windows_Client' }) }
        @{ Name = 'SecurityType'; Label = 'Security type'; Help = 'TrustedLaunch enables Secure Boot (only signed boot loaders run) and a virtual TPM (needed for BitLocker and Windows 11 attestation) on Generation 2 images, at no cost. It is the default for new VMs. Standard is the legacy mode for Gen1 images or software that cannot run under Secure Boot. You cannot switch a VM between them after creation without rebuilding.'; Type = 'Choice'; Required = $true; Default = 'TrustedLaunch'; Options = @('TrustedLaunch', 'Standard') }
        @{ Name = 'LocalAdmin'; Label = 'Local administrator'; Help = 'Not entered here. Get-Credential prompts for the local administrator when the script runs.'; Type = 'Secret' }
    )
    Steps = @(
        @{
            Title      = 'Create the VM'
            What       = 'Creates the VM and any missing NIC, NSG, and public IP, from the image, in the subnet.'
            Why        = 'One call, one resource group, everything named. Takes a few minutes.'
            Cmdlet     = 'New-AzVM'
            Parameters = @{
                Name = '{{VMName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}'
                Image = '{{Image}}'; Size = '{{VMSize}}'; Credential = '{{LocalAdmin}}'
                VirtualNetworkName = '{{VNetName}}'; SubnetName = '{{SubnetName}}'; SecurityGroupName = '{{NsgName}}'; PublicIpAddressName = '{{PipName}}'
                OpenPorts = '{{OpenPorts}}'; LicenseType = '{{LicenseType}}'; SecurityType = '{{SecurityType}}'
            }
            ParameterOrder = @('Name', 'ResourceGroupName', 'Location', 'Image', 'Size', 'Credential', 'VirtualNetworkName', 'SubnetName', 'SecurityGroupName', 'PublicIpAddressName', 'OpenPorts', 'LicenseType', 'SecurityType')
            Output     = 'vm'
        }
    )
    Verify   = @('Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} -Status | Select-Object Name, @{ n = ''Size''; e = { $_.HardwareProfile.VmSize } }, @{ n = ''Power''; e = { $_.Statuses[-1].DisplayStatus } }')
    Rollback = @('Remove-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Leaves the OS disk, NIC, NSG, and public IP behind. See azure.delete.remove-vm-with-disks.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.compute/new-azvm')
    Status   = 'Untested'
}
