# Fake Az modules for the read-only tests. They are written to disk so module
# discovery, autoloading and Get-Module -ListAvailable behave as they do for the
# real modules. Reads return fixtures from $global:FakeAz; every write-capable
# fake records the call and throws, so a test fails if anything reaches one.
$script:FakeAzWrites = @{
    'Az.Accounts'              = 'Get-AzAccessToken', 'Enable-AzContextAutosave', 'Save-AzContext', 'Import-AzContext', 'Clear-AzContext', 'Disconnect-AzAccount'
    'Az.Resources'             = 'New-AzResourceGroup', 'Remove-AzResourceGroup', 'New-AzRoleAssignment', 'Remove-AzResource'
    'Az.Compute'               = 'New-AzVM', 'Remove-AzVM', 'Start-AzVM', 'Stop-AzVM', 'Restart-AzVM', 'Set-AzVM', 'Update-AzVM', 'Invoke-AzVMRunCommand'
    'Az.Network'               = 'Set-AzNetworkSecurityGroup', 'Add-AzNetworkSecurityRuleConfig', 'Remove-AzNetworkSecurityGroup', 'Set-AzVirtualNetwork'
    'Az.DesktopVirtualization' = 'Update-AzWvdSessionHost', 'Remove-AzWvdSessionHost', 'Remove-AzWvdUserSession', 'Disconnect-AzWvdUserSession',
                                 'Send-AzWvdUserSessionMessage', 'Update-AzWvdHostPool', 'New-AzWvdRegistrationInfo', 'Get-AzWvdRegistrationInfo'
}

$script:FakeAzReads = @{
    'Az.Accounts' = @'
function Get-AzContext { [CmdletBinding()] param() Add-FakeAzCall 'Get-AzContext' $PSBoundParameters; if ($global:FakeAz.ContextOverride) { return $global:FakeAz.ContextOverride }; $global:FakeAz.Context }
function Disable-AzContextAutosave {
    [CmdletBinding(SupportsShouldProcess)] param($Scope)
    Add-FakeAzCall 'Disable-AzContextAutosave' $PSBoundParameters
    [pscustomobject]@{ Mode = $global:FakeAz.AutosaveMode }
}
function Connect-AzAccount {
    [CmdletBinding(SupportsShouldProcess)] param($Tenant, $Subscription, [switch]$UseDeviceAuthentication, $Scope)
    Add-FakeAzCall 'Connect-AzAccount' $PSBoundParameters
    $s = $global:FakeAz
    $landed = if ($s.SignInTenant) { $s.SignInTenant } else { $Tenant }
    $subs = @($s.Subscriptions | Where-Object TenantId -eq $landed)
    $sub = if ($s.SignInSubscription) { $s.SignInSubscription } elseif ($Subscription) { $subs | Where-Object Id -eq $Subscription | Select-Object -First 1 }
        elseif (-not $s.SignInWithoutSubscription) { $subs | Select-Object -First 1 }
    $s.Context = New-FakeAzContext -Tenant $landed -Subscription $sub
    [pscustomobject]@{ Context = $s.Context }
}
function Set-AzContext {
    [CmdletBinding(SupportsShouldProcess)] param($Tenant, $Subscription, $Scope)
    Add-FakeAzCall 'Set-AzContext' $PSBoundParameters
    $sub = $global:FakeAz.Subscriptions | Where-Object Id -eq $Subscription | Select-Object -First 1
    $global:FakeAz.Context = New-FakeAzContext -Tenant $Tenant -Subscription $sub
    $global:FakeAz.Context
}
function Get-AzSubscription { [CmdletBinding()] param($TenantId) Add-FakeAzCall 'Get-AzSubscription' $PSBoundParameters; $global:FakeAz.Subscriptions | Where-Object TenantId -eq $TenantId }
function Invoke-AzRestMethod {
    [CmdletBinding(SupportsShouldProcess)] param($Path, $Method, $Payload, $Uri)
    Add-FakeAzCall 'Invoke-AzRestMethod' $PSBoundParameters
    [pscustomobject]@{ StatusCode = $global:FakeAz.PermissionStatus; Content = $global:FakeAz.Permissions }
}
'@
    'Az.Resources' = @'
function Get-AzResourceGroup { [CmdletBinding()] param() Add-FakeAzCall 'Get-AzResourceGroup' $PSBoundParameters; $global:FakeAz.ResourceGroups }
'@
    'Az.Compute' = @'
function Get-AzVM {
    [CmdletBinding()] param($ResourceGroupName, [switch]$Status, $Name, [switch]$UserData)
    Add-FakeAzCall 'Get-AzVM' $PSBoundParameters
    if ($ResourceGroupName -and $ResourceGroupName -in $global:FakeAz.VmReadFailures) { throw "AuthorizationFailed: cannot read $ResourceGroupName" }
    $global:FakeAz.Vms | Where-Object { -not $ResourceGroupName -or $_.ResourceGroupName -eq $ResourceGroupName }
}
'@
    'Az.Network' = @'
function Get-AzVirtualNetwork { [CmdletBinding()] param() Add-FakeAzCall 'Get-AzVirtualNetwork' $PSBoundParameters; $global:FakeAz.VirtualNetworks }
function Get-AzNetworkSecurityGroup { [CmdletBinding()] param() Add-FakeAzCall 'Get-AzNetworkSecurityGroup' $PSBoundParameters; $global:FakeAz.SecurityGroups }
'@
    'Az.DesktopVirtualization' = @'
function Get-AzWvdHostPool { [CmdletBinding()] param($SubscriptionId, $ResourceGroupName, $Name) Add-FakeAzCall 'Get-AzWvdHostPool' $PSBoundParameters; $global:FakeAz.HostPools }
function Get-AzWvdSessionHost {
    [CmdletBinding()] param($SubscriptionId, $ResourceGroupName, $HostPoolName)
    Add-FakeAzCall 'Get-AzWvdSessionHost' $PSBoundParameters
    if ($HostPoolName -in $global:FakeAz.SessionHostReadFailures) { throw "AuthorizationFailed: cannot read $HostPoolName" }
    $global:FakeAz.SessionHosts[$HostPoolName]
}
function Get-AzWvdUserSession { [CmdletBinding()] param($SubscriptionId, $ResourceGroupName, $HostPoolName) Add-FakeAzCall 'Get-AzWvdUserSession' $PSBoundParameters; $global:FakeAz.UserSessions[$HostPoolName] }
function Get-AzWvdApplicationGroup { [CmdletBinding()] param($SubscriptionId) Add-FakeAzCall 'Get-AzWvdApplicationGroup' $PSBoundParameters; $global:FakeAz.AppGroups }
function Get-AzWvdWorkspace { [CmdletBinding()] param($SubscriptionId) Add-FakeAzCall 'Get-AzWvdWorkspace' $PSBoundParameters; $global:FakeAz.Workspaces }
function Get-AzWvdScalingPlan { [CmdletBinding()] param($SubscriptionId) Add-FakeAzCall 'Get-AzWvdScalingPlan' $PSBoundParameters; $global:FakeAz.ScalingPlans }
'@
}

function global:Add-FakeAzCall {
    param([string]$Name, $Bound)
    $copy = @{}
    foreach ($k in $Bound.Keys) { $copy[$k] = $Bound[$k] }
    $global:FakeAz.Calls.Add([pscustomobject]@{ Name = $Name; Parameters = $copy })
    if ($Name -in $global:FakeAz.Fail) { throw "AuthorizationFailed: fixture $Name" }
}

function global:New-FakeAzContext {
    param([string]$Tenant, $Subscription)
    [pscustomobject]@{
        Tenant       = [pscustomobject]@{ Id = $Tenant }
        Account      = [pscustomobject]@{ Id = $global:FakeAz.Account; Type = $global:FakeAz.AccountType }
        Subscription = $(if ($Subscription) { [pscustomobject]@{ Id = $Subscription.Id; Name = $Subscription.Name; TenantId = $Subscription.TenantId } })
    }
}

function New-FakeAzModule {
    # Writes the five fake modules under $Path and returns that directory.
    param([Parameter(Mandatory)][string]$Path)
    foreach ($name in $script:FakeAzReads.Keys) {
        $folder = Join-Path $Path $name
        $null = New-Item -ItemType Directory -Path $folder -Force
        $writes = foreach ($w in $script:FakeAzWrites[$name]) {
            "function $w { `$global:FakeAz.Writes.Add('$w'); throw 'Fake Az write reached: $w' }"
        }
        Set-Content -LiteralPath (Join-Path $folder "$name.psm1") -Value ($script:FakeAzReads[$name] + "`n" + ($writes -join "`n"))
        "@{ RootModule = '$name.psm1'; ModuleVersion = '99.0.0'; FunctionsToExport = '*' }" | Set-Content -LiteralPath (Join-Path $folder "$name.psd1")
    }
    return $Path
}

function New-FakeAzState {
    # A small fictional estate: two subscriptions in one tenant, one in another,
    # two host pools with the usual faults, a network with RDP open to the internet.
    $tenant = 'aaaaaaaa-0000-0000-0000-000000000001'
    $lab = 'bbbbbbbb-0000-0000-0000-000000000001'
    $pool = "/subscriptions/$lab/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/hostpools"
    $vmId = "/subscriptions/$lab/resourceGroups/rg-avd-hosts/providers/Microsoft.Compute/virtualMachines"
    $appGroup = "/subscriptions/$lab/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/applicationgroups"
    $nsgId = "/subscriptions/$lab/resourceGroups/rg-net/providers/Microsoft.Network/networkSecurityGroups/nsg-avd"
    $check = { param($Name, $Result) [pscustomobject]@{ HealthCheckName = $Name; HealthCheckResult = $Result; AdditionalFailureDetailMessage = 'fixture' } }
    @{
        Calls = [System.Collections.Generic.List[object]]::new()
        Writes = [System.Collections.Generic.List[string]]::new()
        AutosaveMode = 'Process'
        Account = 'reader@fixture.example'; AccountType = 'User'
        SignInTenant = $null; SignInSubscription = $null; SignInWithoutSubscription = $false; Context = $null; ContextOverride = $null
        Fail = @()
        Subscriptions = @(
            [pscustomobject]@{ Name = 'Lab'; Id = $lab; SubscriptionId = $lab; State = 'Enabled'; TenantId = $tenant; HomeTenantId = $tenant }
            [pscustomobject]@{ Name = 'Production'; Id = 'bbbbbbbb-0000-0000-0000-000000000002'; SubscriptionId = 'bbbbbbbb-0000-0000-0000-000000000002'; State = 'Enabled'; TenantId = $tenant; HomeTenantId = $tenant }
            [pscustomobject]@{ Name = 'Other tenant'; Id = 'bbbbbbbb-0000-0000-0000-000000000003'; SubscriptionId = 'bbbbbbbb-0000-0000-0000-000000000003'; State = 'Enabled'; TenantId = 'aaaaaaaa-0000-0000-0000-000000000002'; HomeTenantId = 'aaaaaaaa-0000-0000-0000-000000000002' }
        )
        PermissionStatus = 200
        Permissions = '{"value":[{"actions":["*/read"],"notActions":[]}]}'
        ResourceGroups = @(
            [pscustomobject]@{ ResourceGroupName = 'rg-avd'; Location = 'westus3'; ProvisioningState = 'Succeeded'; Tags = @{ owner = 'FIXTURE-SECRET-TAG' } }
            [pscustomobject]@{ ResourceGroupName = 'rg-avd-hosts'; Location = 'westus3'; ProvisioningState = 'Succeeded' }
        )
        VmReadFailures = @()
        Vms = @(
            [pscustomobject]@{ Name = 'avd-0'; ResourceGroupName = 'rg-avd-hosts'; Location = 'westus3'; PowerState = 'VM running'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D4s_v5' }; StorageProfile = [pscustomobject]@{ OsDisk = [pscustomobject]@{ OsType = 'Windows' } }
                UserData = 'FIXTURE-SECRET-USERDATA'; OSProfile = [pscustomobject]@{ AdminUsername = 'FIXTURE-SECRET-ADMIN' } }
            [pscustomobject]@{ Name = 'avd-1'; ResourceGroupName = 'rg-avd-hosts'; Location = 'westus3'; PowerState = 'VM deallocated'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D4s_v5' }; StorageProfile = [pscustomobject]@{ OsDisk = [pscustomobject]@{ OsType = 'Windows' } } }
            [pscustomobject]@{ Name = 'srv-01'; ResourceGroupName = 'rg-servers'; Location = 'westus3'; PowerState = 'VM running'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_B2s' }; StorageProfile = [pscustomobject]@{ OsDisk = [pscustomobject]@{ OsType = 'Linux' } } }
        )
        HostPools = @(
            [pscustomobject]@{ Name = 'hp-lab'; Id = "$pool/hp-lab"; Location = 'westus3'; HostPoolType = 'Pooled'; LoadBalancerType = 'BreadthFirst'
                MaxSessionLimit = 8; StartVMOnConnect = $true; ValidationEnvironment = $false; PreferredAppGroupType = 'Desktop'
                RegistrationInfoToken = 'FIXTURE-SECRET-TOKEN'; CustomRdpProperty = 'FIXTURE-SECRET-RDP' }
            [pscustomobject]@{ Name = 'hp-empty'; Id = "$pool/hp-empty"; Location = 'westus3'; HostPoolType = 'Personal'; LoadBalancerType = 'Persistent'
                MaxSessionLimit = 1; StartVMOnConnect = $false; ValidationEnvironment = $true; RegistrationInfoToken = 'FIXTURE-SECRET-TOKEN' }
        )
        SessionHostReadFailures = @()
        SessionHosts = @{
            'hp-lab' = @(
                [pscustomobject]@{ Name = 'hp-lab/avd-0.corp.example'; Status = 'Available'; AllowNewSession = $true; Session = 2; AgentVersion = '1.0.1'
                    ResourceId = "$vmId/avd-0"; UpdateState = 'Succeeded'; LastHeartBeat = [datetime]'2026-11-04T08:00:00Z'
                    HealthCheckResult = @((& $check 'DomainJoinedCheck' 'HealthCheckSucceeded')) }
                [pscustomobject]@{ Name = 'hp-lab/avd-1.corp.example'; Status = 'Unavailable'; AllowNewSession = $false; Session = 0; AgentVersion = '1.0.0'
                    ResourceId = "$vmId/avd-1"; UpdateState = 'Failed'; UpdateErrorMessage = 'fixture'
                    HealthCheckResult = @((& $check 'DomainJoinedCheck' 'HealthCheckFailed'), (& $check 'FSLogixHealthCheck' 'HealthCheckFailed')) }
                [pscustomobject]@{ Name = 'hp-lab/avd-2.corp.example'; Status = 'Shutdown'; AllowNewSession = $true; Session = 0; AgentVersion = '1.0.1'
                    ResourceId = "$vmId/avd-2"; UpdateState = 'Succeeded'; HealthCheckResult = @() }
            )
            'hp-empty' = @()
        }
        UserSessions = @{
            'hp-lab' = @([pscustomobject]@{ Name = 'hp-lab/avd-0.corp.example/1'; UserPrincipalName = 'user1@fixture.example'; SessionState = 'Active'; ApplicationType = 'Desktop'; CreateTime = [datetime]'2026-11-04T07:30:00Z' })
        }
        AppGroups = @(
            [pscustomobject]@{ Name = 'ag-lab-desktop'; Id = "$appGroup/ag-lab-desktop"; ApplicationGroupType = 'Desktop'; HostPoolArmPath = "$pool/hp-lab" }
            [pscustomobject]@{ Name = 'ag-lab-apps'; Id = "$appGroup/ag-lab-apps"; ApplicationGroupType = 'RemoteApp'; HostPoolArmPath = "$pool/hp-lab" }
        )
        Workspaces = @([pscustomobject]@{ Name = 'ws-lab'; ApplicationGroupReference = @("$appGroup/ag-lab-desktop") })
        ScalingPlans = @([pscustomobject]@{ Name = 'sp-lab'; TimeZone = 'Pacific Standard Time'
            HostPoolReference = @([pscustomobject]@{ HostPoolArmPath = "$pool/hp-lab"; ScalingPlanEnabled = $true })
            Schedule = @([pscustomobject]@{ Name = 'weekdays'; DaysOfWeek = @('Monday', 'Tuesday'); RampUpStartTimeHour = 7; RampUpStartTimeMinute = 0
                PeakStartTimeHour = 9; PeakStartTimeMinute = 0; RampDownStartTimeHour = 17; RampDownStartTimeMinute = 30; OffPeakStartTimeHour = 20; OffPeakStartTimeMinute = 0 }) })
        VirtualNetworks = @([pscustomobject]@{ Name = 'vnet-lab'; ResourceGroupName = 'rg-net'; Location = 'westus3'
            AddressSpace = [pscustomobject]@{ AddressPrefixes = @('10.10.0.0/16') }; DhcpOptions = [pscustomobject]@{ DnsServers = @('10.10.1.4') }
            VirtualNetworkPeerings = @()
            Subnets = @(
                [pscustomobject]@{ Name = 'snet-avd'; AddressPrefix = @('10.10.1.0/24'); NetworkSecurityGroup = [pscustomobject]@{ Id = $nsgId }; NatGateway = $null }
                [pscustomobject]@{ Name = 'snet-servers'; AddressPrefix = @('10.10.2.0/24'); NetworkSecurityGroup = $null; NatGateway = [pscustomobject]@{ Id = 'fixture-nat' } }
            ) })
        SecurityGroups = @([pscustomobject]@{ Name = 'nsg-avd'; ResourceGroupName = 'rg-net'; Subnets = @('x'); NetworkInterfaces = @()
            SecurityRules = @(
                [pscustomobject]@{ Name = 'allow-rdp-internet'; Direction = 'Inbound'; Access = 'Allow'; Protocol = 'Tcp'; SourceAddressPrefix = @('*'); DestinationPortRange = @('3389') }
                [pscustomobject]@{ Name = 'allow-https-office'; Direction = 'Inbound'; Access = 'Allow'; Protocol = 'Tcp'; SourceAddressPrefix = @('203.0.113.0/24'); DestinationPortRange = @('443') }
                [pscustomobject]@{ Name = 'deny-internet'; Direction = 'Inbound'; Access = 'Deny'; Protocol = '*'; SourceAddressPrefix = @('Internet'); DestinationPortRange = @('*') }
            ) })
    }
}
