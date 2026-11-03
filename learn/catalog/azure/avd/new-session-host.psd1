@{
    Id      = 'azure.avd.new-session-host'
    Title   = 'Build an Entra-joined session host'
    Summary = 'VM from the Windows 11 multi-session image, Entra join, AVD agent via DSC with the registration token, VM sign-in rights for the user group. Four commands, in the order the azure repo''s provisioning-order doc explains.'
    Learn   = @(
        'LicenseType Windows_Client is the Azure Hybrid Benefit flag for multi-session Windows. Without it you pay for a Windows licence you already have through M365.'
        'Extensions run serially on a VM. The Entra join extension reboots; the DSC extension (which installs the agent and registers with the pool) waits for it.'
        'The host is usable only when Get-AzWvdSessionHost shows Status Available. DSC succeeding means the agent installed, not that it finished registering.'
        'Active Directory join instead of Entra: swap step 2 for the JsonADDomainExtension and skip the role assignment. See the azure repo''s Join-AvdSessionHost.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Compute', 'Az.Network', 'Az.Resources', 'Az.DesktopVirtualization'); Roles = @('Contributor + User Access Administrator on the resource group') }
    Prerequisites = @('azure.avd.new-host-pool', 'azure.network.new-vnet', 'azure.avd.new-registration-token')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'HostPoolName'; Label = 'Host pool'; Help = 'The AVD host pool: the control-plane object that session hosts register with and that holds the load-balancing, session limit, and RDP settings. Users never see it directly; they see workspaces and app groups attached to it.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdHostPool'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'VM name (max 15 chars)'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'String'; Required = $true; Pattern = '^[A-Za-z0-9-]{1,15}$'; Example = 'avd-lab-01' }
        @{ Name = 'VMSize'; Label = 'VM size'; Help = 'The VM SKU, read like Standard_D4s_v5: family D (general purpose; B = burstable/cheap, E = memory heavy, F = compute heavy, N = GPU), 4 vCPUs, s = supports premium SSD disks, v5 = hardware generation. Multi-session AVD hosts are usually D4s_v5 or D8s_v5 (4 to 8 vCPU, 16 to 32 GB). Pick an s size if you want premium disks. The list comes from Get-AzVMSize for the region.'; Type = 'Choice'; Required = $true; Default = 'Standard_D4s_v5'
           Source = @{ Cmdlet = 'Get-AzVMSize'; Parameters = @{ Location = '{{Location}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'ImageOffer'; Label = 'Marketplace offer'; Help = 'Second part of the marketplace URN (Publisher:Offer:SKU:Version). For MicrosoftWindowsDesktop, offer office-365 contains the Windows multi-session images with Microsoft 365 Apps preinstalled; offer windows-11 contains plain Windows 11 (single and multi-session) without Office.'; Type = 'Choice'; Required = $true; Default = 'office-365'
           Options = @(@{ Display = 'office-365 (multi-session + M365 Apps)'; Value = 'office-365' }, @{ Display = 'windows-11 (multi-session, no Office)'; Value = 'windows-11' }) }
        @{ Name = 'ImageSku'; Label = 'Image SKU'; Type = 'Choice'; Required = $true; Default = 'win11-24h2-avd-m365'
           Options = @('win11-24h2-avd-m365', 'win11-23h2-avd-m365', 'win11-24h2-avd', 'win11-23h2-avd'); Help = 'Third part of the marketplace URN. win11-24h2-avd-m365 = Windows 11 24H2, avd = Enterprise multi-session (several users share one VM; only licensed for AVD), m365 = Microsoft 365 Apps preinstalled. SKUs without avd are single-session. List live values with Get-AzVMImageSku -Location <region> -PublisherName MicrosoftWindowsDesktop -Offer <offer>.' }
        @{ Name = 'VNetName'; Label = 'Virtual network'; Help = 'The virtual network. Subnets live inside it; NICs attach to subnets.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVirtualNetwork'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SubnetName'; Label = 'Subnet name'; Help = 'The subnet inside the VNet. NICs, VMs, and session hosts are placed in a subnet.'; Type = 'String'; Required = $true; Default = 'snet-hosts' }
        @{ Name = 'GroupObjectId'; Label = 'Entra group of AVD users (gets VM sign-in rights)'; Help = 'The Entra group''s object ID (a GUID), which is what Azure RBAC stores; the list shows display names and writes the ID. Assign roles to groups rather than users so access changes are a membership change, not an Azure change.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzADGroup'; Display = 'DisplayName'; Value = 'Id'; Auth = 'Azure' } }
        @{ Name = 'SecurityType'; Label = 'Security type'; Help = 'TrustedLaunch enables Secure Boot (only signed boot loaders run) and a virtual TPM (needed for BitLocker and Windows 11 attestation) on Generation 2 images, at no cost. It is the default for new VMs. Standard is the legacy mode for Gen1 images or software that cannot run under Secure Boot. You cannot switch a VM between them after creation without rebuilding.'; Type = 'Choice'; Required = $true; Default = 'TrustedLaunch'; Options = @('TrustedLaunch', 'Standard') }
        @{ Name = 'LicenseType'; Label = 'Hybrid Benefit licence'; Help = 'Azure Hybrid Benefit: tells Azure you already own the Windows licence so it stops charging for one. Windows_Client is for Windows 10/11 Enterprise multi-session, covered by Microsoft 365 E3/E5, Business Premium, or Windows E3/E5 per user. Windows_Server is for Windows Server with Software Assurance. None means pay-as-you-go. Setting it when you are not entitled is a licensing violation, not a technical error.'; Type = 'Choice'; Required = $true; Default = 'Windows_Client'; Options = @(@{ Display = 'Windows_Client (multi-session via M365 licence)'; Value = 'Windows_Client' }, @{ Display = 'None (pay as you go)'; Value = 'None' }) }
        @{ Name = 'ImagePublisher'; Label = 'Image publisher'; Help = 'First part of the marketplace URN. MicrosoftWindowsDesktop publishes Windows 10/11 client images (including multi-session); MicrosoftWindowsServer publishes Windows Server; Canonical publishes Ubuntu.'; Type = 'String'; Required = $true; Default = 'MicrosoftWindowsDesktop' }
        @{ Name = 'ImageVersion'; Label = 'Image version'; Help = 'Fourth part of the URN. latest resolves to the newest build when the VM is created, which is what you want for a fresh host. Pin an exact version (e.g. 26100.4349.250607) when every host in a pool must be identical or when a newer image broke something.'; Type = 'String'; Required = $true; Default = 'latest' }
        @{ Name = 'EntraExtensionVersion'; Label = 'AADLoginForWindows extension version'; Help = 'Version of the AADLoginForWindows VM extension, which joins the VM to Entra ID and lets Entra accounts sign in at the Windows logon screen. 2.0 is the current major; check the extension docs before moving.'; Type = 'String'; Required = $true; Default = '2.0'; Pattern = '^\d+\.\d+$' }
        @{ Name = 'DscExtensionVersion'; Label = 'DSC extension version'; Help = 'Version of the Azure PowerShell DSC extension handler (Publisher Microsoft.Powershell, type DSC) that runs the AVD configuration inside the VM. 2.73 has been the stable choice for years; the handler auto-updates minor versions when AutoUpgradeMinorVersion is on.'; Type = 'String'; Required = $true; Default = '2.73'; Pattern = '^\d+\.\d+$' }
        @{ Name = 'DscArtifactsUrl'; Label = 'AVD agent DSC artifacts URL'; Help = 'The ZIP Microsoft hosts containing the PowerShell DSC (Desired State Configuration) script that installs the AVD agent and boot loader and registers the host. DSC is the extension mechanism; the URL is the same one the portal uses. Change it only if Microsoft publishes a new one or you host your own copy.'; Type = 'String'; Required = $true; Default = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration.zip' }
        @{ Name = 'VmLoginRole'; Label = 'VM sign-in role for the group'; Help = 'Entra-joined VMs check an Azure RBAC role at logon. Virtual Machine User Login gives a standard session (right for AVD users). Virtual Machine Administrator Login gives local admin on the host. Neither is inherited from Desktop Virtualization User, which only publishes the desktop.'; Type = 'Choice'; Required = $true; Default = 'Virtual Machine User Login'; Options = @('Virtual Machine User Login', 'Virtual Machine Administrator Login') }
        @{ Name = 'LocalAdmin'; Label = 'Local administrator for the VM'; Help = 'Not entered here. Get-Credential prompts for the local administrator when the script runs.'; Type = 'Secret' }
        @{ Name = 'RegistrationToken'; Label = 'Host pool registration token (from the previous task)'; Help = 'A time-limited secret issued per host pool that the AVD agent presents to join the pool. Generated by the registration-token task. Not entered here: the generated script prompts for it when run, and the DSC extension stores it in protected settings that cannot be read back.'; Type = 'Secret'; SecretKind = 'PlainText' }
    )
    Steps = @(
        @{
            Title = 'Create the NIC in the host subnet'
            What  = 'A NIC named after the VM, no public IP.'
            Why   = 'Session hosts are reached through the AVD gateway, never directly. Creating the NIC yourself keeps its private IP across a reimage.'
            Raw   = @('New-AzNetworkInterface -Name ''{{VMName:raw}}-nic'' -ResourceGroupName {{ResourceGroupName}} -Location {{Location}} -SubnetId ((Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}}).Subnets | Where-Object Name -eq {{SubnetName}}).Id')
        }
        @{
            Title = 'Create the VM from the multi-session image'
            What  = 'Builds the VM config in memory (size, Trusted Launch, system identity, Windows_Client licence, OS, image, NIC) and creates it in one call.'
            Why   = 'The config pipeline is the long-form New-AzVM. Each Set-* adds one part; nothing is created until New-AzVM.'
            Fixed = @('IdentityType', 'Windows', 'ProvisionVMAgent', 'Disable')
            Raw   = @('New-AzVM -ResourceGroupName {{ResourceGroupName}} -Location {{Location}} -VM (New-AzVMConfig -VMName {{VMName}} -VMSize {{VMSize}} -SecurityType {{SecurityType}} -IdentityType SystemAssigned -LicenseType {{LicenseType}} | Set-AzVMOperatingSystem -Windows -ComputerName {{VMName}} -Credential {{LocalAdmin}} -ProvisionVMAgent | Set-AzVMSourceImage -PublisherName {{ImagePublisher}} -Offer {{ImageOffer}} -Skus {{ImageSku}} -Version {{ImageVersion}} | Add-AzVMNetworkInterface -Id (Get-AzNetworkInterface -Name ''{{VMName:raw}}-nic'' -ResourceGroupName {{ResourceGroupName}}).Id | Set-AzVMBootDiagnostic -Disable)')
        }
        @{
            Title      = 'Entra join'
            What       = 'Installs AADLoginForWindows. The VM reboots.'
            Why        = 'The AVD agent registers the host under its Entra identity; join first.'
            Cmdlet     = 'Set-AzVMExtension'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; VMName = '{{VMName}}'; Location = '{{Location}}'; Name = '''AADLoginForWindows'''; Publisher = '''Microsoft.Azure.ActiveDirectory'''; ExtensionType = '''AADLoginForWindows'''; TypeHandlerVersion = '{{EntraExtensionVersion}}' }
            ParameterOrder = @('ResourceGroupName', 'VMName', 'Location', 'Name', 'Publisher', 'ExtensionType', 'TypeHandlerVersion')
            Fixed          = @('Name', 'Publisher', 'ExtensionType')
        }
        @{
            Title      = 'Install the AVD agent and register with the pool (DSC)'
            What       = 'The DSC extension downloads Microsoft''s AddSessionHost configuration, installs the agent and boot loader, and registers using the token.'
            Why        = 'Same mechanism the portal uses. The token goes in ProtectedSettings so it is not readable afterwards.'
            Cmdlet     = 'Set-AzVMExtension'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; VMName = '{{VMName}}'; Location = '{{Location}}'; Name = '''AvdAgentDsc'''; Publisher = '''Microsoft.Powershell'''; ExtensionType = '''DSC'''; TypeHandlerVersion = '{{DscExtensionVersion}}'
                Settings = '@{ modulesUrl = {{DscArtifactsUrl}}; configurationFunction = ''Configuration.ps1\AddSessionHost''; properties = @{ hostPoolName = {{HostPoolName}}; aadJoin = $true } }'
                ProtectedSettings = '@{ properties = @{ registrationInfoToken = {{RegistrationToken}} } }' }
            ParameterOrder = @('ResourceGroupName', 'VMName', 'Location', 'Name', 'Publisher', 'ExtensionType', 'TypeHandlerVersion', 'Settings', 'ProtectedSettings')
            Fixed          = @('Name', 'Publisher', 'ExtensionType')
        }
        @{
            Title = 'Let the user group sign in to the VM'
            What  = 'Virtual Machine User Login on the VM for the AVD users group.'
            Why   = 'Entra-joined VMs require this role for interactive logon; Desktop Virtualization User on the app group is not enough.'
            Raw   = @('New-AzRoleAssignment -ObjectId {{GroupObjectId}} -RoleDefinitionName {{VmLoginRole}} -Scope (Get-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}}).Id')
        }
    )
    Verify   = @('Get-AzWvdSessionHost -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} | Select-Object Name, Status, AllowNewSession, AgentVersion, LastHeartBeat')
    Rollback = @('Remove-AzVM -Name {{VMName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Then the OS disk and {{VMName:raw}}-nic (azure.delete.remove-vm-with-disks), and Remove-AzWvdSessionHost so the pool forgets it.')
    Docs     = @('https://learn.microsoft.com/azure/virtual-desktop/add-session-hosts-host-pool', 'https://learn.microsoft.com/powershell/module/az.compute/set-azvmextension')
    Status   = 'Untested'
}
