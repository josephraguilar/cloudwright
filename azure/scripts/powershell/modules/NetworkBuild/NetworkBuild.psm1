#region Module setup ----------------------------------------------------------
#   WHAT   Virtual networks, subnets and NSGs: flat listings, create, and the edits
#          that are safe to offer: DNS servers, added address space, subnet prefix,
#          NSG attach or detach.
#   WHY    Same shape as the other modules: one function per step, -WhatIf on every
#          change, objects out. Nothing here deletes a network, a subnet or an NSG,
#          and address space can only grow, because shrinking it is the one network
#          edit that takes things down.
#   GOTCHA A VNet is edited by changing the object and calling Set-AzVirtualNetwork
#          once, which writes the whole thing back. Every edit here re-reads the
#          VNet first so it never writes a stale copy over someone else's change.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
#endregion

#region Lookups ---------------------------------------------------------------
function Split-NetResourceId {
    param([Parameter(Mandatory)] [string]$Id)
    $p = $Id -split '/'
    [pscustomobject]@{ ResourceGroupName = $p[4]; Name = $p[-1]; VirtualNetworkName = $(if ($p.Count -ge 9) { $p[8] } else { $null }) }
}

function Get-NetVirtualNetworkObject {
    param([Parameter(Mandatory)] [string]$VirtualNetworkId)
    $r = Split-NetResourceId $VirtualNetworkId
    return Get-AzVirtualNetwork -ResourceGroupName $r.ResourceGroupName -Name $r.Name -ErrorAction Stop
}

function Test-NetCidr {
    <#
    .SYNOPSIS
        True for an IPv4 CIDR like 10.10.0.0/16.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') { return $false }
    foreach ($o in $Matches[1..4]) { if ([int]$o -gt 255) { return $false } }
    return ([int]$Matches[5] -le 32)
}

#region Address maths ----------------------------------------------------------
#   WHAT   Pure helpers (no Azure calls): is a subnet prefix inside the VNet, does
#          it overlap a sibling, which /N is the first free one. The GUI's Add
#          subnet dialog and New-NetSubnet / Set-NetSubnet use the same rules, so a
#          bad prefix is refused before Azure is asked.
function ConvertTo-NetRange {
    param([string]$Cidr)
    $ip, $len = $Cidr -split '/'
    $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes(); [array]::Reverse($b)
    $start = [uint64][BitConverter]::ToUInt32($b, 0)
    $size = [uint64][math]::Pow(2, 32 - [int]$len)
    [pscustomobject]@{ Start = $start; End = $start + $size - 1; Size = $size; Length = [int]$len; Aligned = (($start % $size) -eq 0) }
}

function ConvertFrom-NetIpNumber {
    param([uint64]$Number)
    $b = [BitConverter]::GetBytes([uint32]$Number); [array]::Reverse($b)
    return ([System.Net.IPAddress]::new($b)).ToString()
}

function Split-NetPrefixList {
    param([string[]]$Prefix)
    return @($Prefix | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ })
}

function Test-NetSubnetPrefix {
    <#
    .SYNOPSIS
        Problems with a subnet prefix, as sentences; none means it is fine. Checks
        the CIDR form, Azure's /29 minimum, host bits, that it sits inside the VNet's
        address space, and that it overlaps no other subnet.
    .PARAMETER Existing
        Other subnets of the VNet: name -> prefix (a prefix may list several).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Prefix,
        [Parameter(Mandatory)] [string[]]$AddressSpace,
        [Parameter()] [hashtable]$Existing = @{}
    )
    if (-not (Test-NetCidr $Prefix)) { return @("'$Prefix' is not a CIDR like 10.10.2.0/24.") }
    $r = ConvertTo-NetRange $Prefix
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($r.Length -gt 29) { $problems.Add('Azure subnets are /29 or larger (Azure keeps 5 addresses of each).') }
    if (-not $r.Aligned) {
        $net = ConvertFrom-NetIpNumber ([uint64]([math]::Floor($r.Start / $r.Size) * $r.Size))
        $problems.Add("$Prefix has host bits set; the network address is $net/$($r.Length).")
    }
    $spaces = @(Split-NetPrefixList $AddressSpace | Where-Object { Test-NetCidr $_ })
    $inside = @($spaces | Where-Object { $s = ConvertTo-NetRange $_; $r.Start -ge $s.Start -and $r.End -le $s.End })
    if ($inside.Count -eq 0) { $problems.Add("$Prefix is outside the network's address space ($($spaces -join ', ')).") }
    foreach ($name in $Existing.Keys) {
        foreach ($other in Split-NetPrefixList @($Existing[$name])) {
            if (-not (Test-NetCidr $other)) { continue }
            $o = ConvertTo-NetRange $other
            if ($r.Start -eq $o.Start -and $r.End -eq $o.End) { $problems.Add("$Prefix already exists: subnet $name uses it.") }
            elseif ($r.Start -le $o.End -and $o.Start -le $r.End) { $problems.Add("$Prefix overlaps subnet $name ($other).") }
        }
    }
    return $problems.ToArray()
}

function Get-NetFreeSubnetPrefix {
    <#
    .SYNOPSIS
        Free /PrefixLength blocks inside the address space that no subnet uses.
        Without -All, the one to suggest: the first free block after the highest
        subnet in use (what people expect "next" to mean), else the first free one.
        With -All, every free block (up to -Max), that suggestion first, then the
        rest after it, then the gaps before it. Nothing when the space is full.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string[]]$AddressSpace,
        [Parameter()] [string[]]$Used = @(),
        [Parameter()] [ValidateRange(8, 29)] [int]$PrefixLength = 24,
        [Parameter()] [switch]$All,
        [Parameter()] [ValidateRange(1, 4096)] [int]$Max = 256
    )
    $taken = @(Split-NetPrefixList $Used | Where-Object { Test-NetCidr $_ } | ForEach-Object { ConvertTo-NetRange $_ })
    $highest = if ($taken.Count) { ($taken | Measure-Object -Property End -Maximum).Maximum } else { -1 }
    $after = [System.Collections.Generic.List[string]]::new()
    $before = [System.Collections.Generic.List[string]]::new()
    foreach ($space in Split-NetPrefixList $AddressSpace | Where-Object { Test-NetCidr $_ }) {
        $s = ConvertTo-NetRange $space
        if ($PrefixLength -lt $s.Length) { continue }
        $size = [uint64][math]::Pow(2, 32 - $PrefixLength)
        for ($start = $s.Start; $start + $size - 1 -le $s.End -and ($after.Count + $before.Count) -lt $Max; $start += $size) {
            $end = $start + $size - 1
            if (@($taken | Where-Object { $start -le $_.End -and $_.Start -le $end }).Count -gt 0) { continue }
            $cidr = "$(ConvertFrom-NetIpNumber $start)/$PrefixLength"
            if ([double]$start -gt [double]$highest) { $after.Add($cidr) } else { $before.Add($cidr) }
        }
    }
    $ordered = @($after) + @($before)
    if ($All) { return $ordered }
    return ($ordered | Select-Object -First 1)
}
#endregion

function Get-NetVirtualNetworkInfo {
    <#
    .SYNOPSIS
        Virtual networks as flat rows: address space, DNS, subnet count, peerings.
    #>
    [CmdletBinding()]
    param([Parameter()] [string]$ResourceGroupName)
    $vnets = if ($ResourceGroupName) { @(Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName) } else { @(Get-AzVirtualNetwork) }
    foreach ($v in $vnets | Sort-Object ResourceGroupName, Name) {
        $dns = @($v.DhcpOptions.DnsServers)
        [pscustomobject]@{
            Name              = $v.Name
            ResourceGroupName = $v.ResourceGroupName
            Location          = $v.Location
            AddressSpace      = (@($v.AddressSpace.AddressPrefixes) -join ', ')
            DnsServers        = $(if ($dns.Count -gt 0) { $dns -join ', ' } else { 'Azure default' })
            Subnets           = @($v.Subnets).Count
            Peerings          = @($v.VirtualNetworkPeerings).Count
            Id                = $v.Id
        }
    }
}

function Get-NetSubnetInfo {
    <#
    .SYNOPSIS
        Subnets of one VNet (or every VNet) as flat rows: prefix, NSG, route table,
        delegations, and how many NICs sit in it.
    #>
    [CmdletBinding()]
    param([Parameter()] [string]$VirtualNetworkId)
    $vnets = if ($VirtualNetworkId) { @(Get-NetVirtualNetworkObject $VirtualNetworkId) } else { @(Get-AzVirtualNetwork) }
    foreach ($v in $vnets) {
        foreach ($s in @($v.Subnets)) {
            $prefixes = if ($s.AddressPrefix) { @($s.AddressPrefix) } else { @() }
            [pscustomobject]@{
                Name           = $s.Name
                VirtualNetwork = $v.Name
                AddressPrefix  = ($prefixes -join ', ')
                Nsg            = $(if ($s.NetworkSecurityGroup -and $s.NetworkSecurityGroup.Id) { (Split-NetResourceId $s.NetworkSecurityGroup.Id).Name } else { '' })
                RouteTable     = $(if ($s.RouteTable -and $s.RouteTable.Id) { (Split-NetResourceId $s.RouteTable.Id).Name } else { '' })
                Delegation     = (@($s.Delegations | ForEach-Object { $_.ServiceName }) -join ', ')
                Nics           = @($s.IpConfigurations).Count
                Id             = $s.Id
                NsgId          = $(if ($s.NetworkSecurityGroup) { $s.NetworkSecurityGroup.Id } else { '' })
            }
        }
    }
}

function Get-NetSecurityGroupInfo {
    <#
    .SYNOPSIS
        NSGs as flat rows, for a picker.
    #>
    [CmdletBinding()]
    param([Parameter()] [string]$ResourceGroupName)
    $nsgs = if ($ResourceGroupName) { @(Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName) } else { @(Get-AzNetworkSecurityGroup) }
    foreach ($n in $nsgs | Sort-Object ResourceGroupName, Name) {
        [pscustomobject]@{
            Name = $n.Name; ResourceGroupName = $n.ResourceGroupName; Location = $n.Location
            Rules = @($n.SecurityRules).Count; Subnets = @($n.Subnets).Count; Nics = @($n.NetworkInterfaces).Count; Id = $n.Id
        }
    }
}
#endregion

#region Create ----------------------------------------------------------------
function New-NetVirtualNetwork {
    <#
    .SYNOPSIS
        A VNet with one subnet. Returns the existing one untouched if the name is taken.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string[]]$AddressPrefix,
        [Parameter(Mandatory)] [string]$SubnetName,
        [Parameter(Mandatory)] [string]$SubnetPrefix,
        [Parameter()] [string[]]$DnsServer,
        [Parameter()] [string]$NetworkSecurityGroupId,
        [Parameter()] [hashtable]$Tags = @{}
    )
    foreach ($p in $AddressPrefix + $SubnetPrefix) { if (-not (Test-NetCidr $p)) { throw "'$p' is not an IPv4 CIDR like 10.10.0.0/16." } }
    $existing = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "VNet $Name already exists; leaving it as is."; return $existing }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create VNet $($AddressPrefix -join ', ') in $Location with subnet $SubnetName $SubnetPrefix")) { return }
    $sp = @{ Name = $SubnetName; AddressPrefix = $SubnetPrefix }
    if ($NetworkSecurityGroupId) { $sp.NetworkSecurityGroupId = $NetworkSecurityGroupId }
    $subnet = New-AzVirtualNetworkSubnetConfig @sp
    $vp = @{ Name = $Name; ResourceGroupName = $ResourceGroupName; Location = $Location; AddressPrefix = $AddressPrefix; Subnet = $subnet; Tag = $Tags }
    if ($DnsServer) { $vp.DnsServer = $DnsServer }
    Write-Verbose "Creating VNet $Name."
    return New-AzVirtualNetwork @vp
}

function New-NetSubnet {
    <#
    .SYNOPSIS
        Adds a subnet to a VNet, optionally with an NSG. Existing name: returned untouched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VirtualNetworkId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$AddressPrefix,
        [Parameter()] [string]$NetworkSecurityGroupId
    )
    if (-not (Test-NetCidr $AddressPrefix)) { throw "'$AddressPrefix' is not an IPv4 CIDR." }
    $vnet = Get-NetVirtualNetworkObject $VirtualNetworkId
    if ($vnet.Subnets | Where-Object Name -eq $Name) { Write-Verbose "Subnet $Name already exists on $($vnet.Name)."; return ($vnet.Subnets | Where-Object Name -eq $Name) }
    $others = @{}; foreach ($sn in @($vnet.Subnets)) { $others[$sn.Name] = @($sn.AddressPrefix) }
    $problems = @(Test-NetSubnetPrefix -Prefix $AddressPrefix -AddressSpace @($vnet.AddressSpace.AddressPrefixes) -Existing $others)
    if ($problems.Count -gt 0) { throw ($problems -join ' ') }
    if (-not $PSCmdlet.ShouldProcess("$($vnet.Name)/$Name", "Add subnet $AddressPrefix$(if ($NetworkSecurityGroupId) { ' with NSG ' + (Split-NetResourceId $NetworkSecurityGroupId).Name })")) { return }
    $p = @{ Name = $Name; AddressPrefix = $AddressPrefix; VirtualNetwork = $vnet }
    if ($NetworkSecurityGroupId) { $p.NetworkSecurityGroupId = $NetworkSecurityGroupId }
    $null = Add-AzVirtualNetworkSubnetConfig @p
    Write-Verbose "Adding subnet $Name $AddressPrefix to $($vnet.Name)."
    $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
    return ($vnet.Subnets | Where-Object Name -eq $Name)
}

function New-NetSecurityGroup {
    <#
    .SYNOPSIS
        An NSG with only the default rules (deny inbound from the internet, allow VNet).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [hashtable]$Tags = @{}
    )
    $existing = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "NSG $Name already exists."; return $existing }
    if ($PSCmdlet.ShouldProcess($Name, "Create NSG in $Location")) {
        Write-Verbose "Creating NSG $Name."
        return New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location -Tag $Tags
    }
}
#endregion

#region Edit ------------------------------------------------------------------
function Set-NetVirtualNetworkDnsServer {
    <#
    .SYNOPSIS
        Set a VNet's DNS servers, or -AzureDefault to go back to Azure-provided DNS.
        VMs pick the change up on their next restart (or an ipconfig /renew).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VirtualNetworkId,
        [Parameter(ParameterSetName = 'Custom', Mandatory)] [string[]]$DnsServer,
        [Parameter(ParameterSetName = 'Default', Mandatory)] [switch]$AzureDefault
    )
    $vnet = Get-NetVirtualNetworkObject $VirtualNetworkId
    $current = @($vnet.DhcpOptions.DnsServers)
    $wanted = if ($AzureDefault) { @() } else { @($DnsServer | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    foreach ($ip in $wanted) { if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "'$ip' is not an IPv4 address." } }
    if (($current -join ',') -eq ($wanted -join ',')) { Write-Verbose "DNS on $($vnet.Name) unchanged."; return $vnet }
    $what = if ($wanted.Count -eq 0) { 'Azure default' } else { $wanted -join ', ' }
    if ($PSCmdlet.ShouldProcess($vnet.Name, "Set DNS servers to $what (was: $(if ($current.Count) { $current -join ', ' } else { 'Azure default' }))")) {
        if (-not $vnet.DhcpOptions) { $vnet.DhcpOptions = [Microsoft.Azure.Commands.Network.Models.PSDhcpOptions]::new() }
        $vnet.DhcpOptions.DnsServers = [System.Collections.Generic.List[string]]$wanted
        Write-Verbose "DNS on $($vnet.Name) -> $what."
        return Set-AzVirtualNetwork -VirtualNetwork $vnet
    }
}

function Add-NetAddressSpace {
    <#
    .SYNOPSIS
        Adds an address prefix to a VNet. Prefixes are never removed here.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VirtualNetworkId,
        [Parameter(Mandatory)] [string]$AddressPrefix
    )
    if (-not (Test-NetCidr $AddressPrefix)) { throw "'$AddressPrefix' is not an IPv4 CIDR." }
    $vnet = Get-NetVirtualNetworkObject $VirtualNetworkId
    if (@($vnet.AddressSpace.AddressPrefixes) -contains $AddressPrefix) { Write-Verbose "$($vnet.Name) already has $AddressPrefix."; return $vnet }
    if ($PSCmdlet.ShouldProcess($vnet.Name, "Add address space $AddressPrefix")) {
        $vnet.AddressSpace.AddressPrefixes.Add($AddressPrefix)
        Write-Verbose "Adding $AddressPrefix to $($vnet.Name)."
        return Set-AzVirtualNetwork -VirtualNetwork $vnet
    }
}

function Set-NetSubnet {
    <#
    .SYNOPSIS
        Change a subnet's prefix, attach an NSG, or detach it. Only what you pass changes.
    .NOTES
        A prefix change is refused by Azure while NICs sit in the subnet; the
        error says so. Detaching an NSG from a subnet whose VMs have no NIC-level
        NSG leaves them governed by nothing but Azure's defaults.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VirtualNetworkId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [string]$AddressPrefix,
        [Parameter()] [string]$NetworkSecurityGroupId,
        [Parameter()] [switch]$DetachNetworkSecurityGroup
    )
    if ($AddressPrefix -and -not (Test-NetCidr $AddressPrefix)) { throw "'$AddressPrefix' is not an IPv4 CIDR." }
    $vnet = Get-NetVirtualNetworkObject $VirtualNetworkId
    $subnet = $vnet.Subnets | Where-Object Name -eq $Name | Select-Object -First 1
    if (-not $subnet) { throw "Subnet $Name not found on $($vnet.Name)." }
    $changes = @()
    if ($AddressPrefix -and (@($subnet.AddressPrefix) -join ',') -ne $AddressPrefix) {
        $others = @{}; foreach ($sn in @($vnet.Subnets | Where-Object Name -ne $Name)) { $others[$sn.Name] = @($sn.AddressPrefix) }
        $problems = @(Test-NetSubnetPrefix -Prefix $AddressPrefix -AddressSpace @($vnet.AddressSpace.AddressPrefixes) -Existing $others)
        if ($problems.Count -gt 0) { throw ($problems -join ' ') }
        $subnet.AddressPrefix = [System.Collections.Generic.List[string]]@($AddressPrefix); $changes += "prefix $AddressPrefix"
    }
    if ($DetachNetworkSecurityGroup) {
        if ($subnet.NetworkSecurityGroup) { $subnet.NetworkSecurityGroup = $null; $changes += 'NSG detached' }
    } elseif ($NetworkSecurityGroupId) {
        $currentId = if ($subnet.NetworkSecurityGroup) { $subnet.NetworkSecurityGroup.Id } else { '' }
        if ($currentId -ne $NetworkSecurityGroupId) {
            $r = Split-NetResourceId $NetworkSecurityGroupId
            $subnet.NetworkSecurityGroup = Get-AzNetworkSecurityGroup -ResourceGroupName $r.ResourceGroupName -Name $r.Name -ErrorAction Stop
            $changes += "NSG $($r.Name)"
        }
    }
    if ($changes.Count -eq 0) { Write-Verbose "Subnet $Name unchanged."; return $subnet }
    if ($PSCmdlet.ShouldProcess("$($vnet.Name)/$Name", "Update subnet: $($changes -join ', ')")) {
        Write-Verbose "Updating subnet $Name ($($changes -join ', '))."
        $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
        return ($vnet.Subnets | Where-Object Name -eq $Name)
    }
}
#endregion

#region NSG rules -------------------------------------------------------------
#   GOTCHA "Remove a rule" here means set it to Deny: the rule stays, visible and
#          reversible. An Allow rule inbound from the whole internet (*, Internet,
#          0.0.0.0/0) is refused unless -AllowInternetSource says it is meant; the
#          usual right answer is your own public IP, or Generate RDP for 3389.
$script:InternetSources = @('*', 'Internet', '0.0.0.0/0', 'Any')

function Get-NetSecurityRuleInfo {
    <#
    .SYNOPSIS
        Rules of one NSG, by direction and priority. -IncludeDefault adds Azure's
        built-in rules (65000 and up), which cannot be changed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$NetworkSecurityGroupId,
        [Parameter()] [switch]$IncludeDefault
    )
    $r = Split-NetResourceId $NetworkSecurityGroupId
    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $r.ResourceGroupName -Name $r.Name
    $rules = @($nsg.SecurityRules | ForEach-Object { $_ | Add-Member -NotePropertyName IsDefault -NotePropertyValue $false -PassThru -Force })
    if ($IncludeDefault) { $rules += @($nsg.DefaultSecurityRules | ForEach-Object { $_ | Add-Member -NotePropertyName IsDefault -NotePropertyValue $true -PassThru -Force }) }
    foreach ($x in $rules | Sort-Object Direction, Priority) {
        [pscustomobject]@{
            Name        = $x.Name
            Priority    = [int]$x.Priority
            Direction   = "$($x.Direction)"
            Access      = "$($x.Access)"
            Protocol    = "$($x.Protocol)"
            Source      = (@($x.SourceAddressPrefix) -join ', ')
            SourcePorts = (@($x.SourcePortRange) -join ', ')
            Destination = (@($x.DestinationAddressPrefix) -join ', ')
            Ports       = (@($x.DestinationPortRange) -join ', ')
            Description = "$($x.Description)"
            Default     = [bool]$x.IsDefault
        }
    }
}

function Set-NetSecurityRule {
    <#
    .SYNOPSIS
        Add a rule to an NSG, or change one with the same name. Only Allow or Deny,
        never removal. Priority must be free in that direction.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$NetworkSecurityGroupId,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')] [string]$Name,
        [Parameter(Mandatory)] [ValidateRange(100, 4096)] [int]$Priority,
        [Parameter(Mandatory)] [ValidateSet('Inbound', 'Outbound')] [string]$Direction,
        [Parameter(Mandatory)] [ValidateSet('Allow', 'Deny')] [string]$Access,
        [Parameter()] [ValidateSet('Tcp', 'Udp', 'Icmp', '*')] [string]$Protocol = 'Tcp',
        [Parameter()] [string[]]$SourceAddressPrefix = @('VirtualNetwork'),
        [Parameter()] [string[]]$SourcePortRange = @('*'),
        [Parameter()] [string[]]$DestinationAddressPrefix = @('*'),
        [Parameter(Mandatory)] [string[]]$DestinationPortRange,
        [Parameter()] [string]$Description,
        [Parameter()] [switch]$AllowInternetSource
    )
    if ($Access -eq 'Allow' -and $Direction -eq 'Inbound' -and -not $AllowInternetSource) {
        $open = @($SourceAddressPrefix | Where-Object { $_ -in $script:InternetSources })
        if ($open.Count -gt 0) { throw "An inbound Allow from '$($open -join ', ')' opens port(s) $($DestinationPortRange -join ', ') to the whole internet. Use your own IP or a known range, or pass -AllowInternetSource if this is really meant." }
    }
    $r = Split-NetResourceId $NetworkSecurityGroupId
    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $r.ResourceGroupName -Name $r.Name
    $existing = $nsg.SecurityRules | Where-Object Name -eq $Name | Select-Object -First 1
    $clash = $nsg.SecurityRules | Where-Object { $_.Name -ne $Name -and "$($_.Direction)" -eq $Direction -and [int]$_.Priority -eq $Priority } | Select-Object -First 1
    if ($clash) { throw "Priority $Priority $Direction is already used by $($clash.Name)." }
    $p = @{
        NetworkSecurityGroup = $nsg; Name = $Name; Priority = $Priority; Direction = $Direction; Access = $Access; Protocol = $Protocol
        SourceAddressPrefix = $SourceAddressPrefix; SourcePortRange = $SourcePortRange
        DestinationAddressPrefix = $DestinationAddressPrefix; DestinationPortRange = $DestinationPortRange
    }
    if ($Description) { $p.Description = $Description }
    $verb = if ($existing) { 'Change' } else { 'Add' }
    if (-not $PSCmdlet.ShouldProcess("$($r.Name)/$Name", "$verb rule: $Access $Direction $Protocol from $($SourceAddressPrefix -join ',') to $($DestinationAddressPrefix -join ','):$($DestinationPortRange -join ',') at $Priority")) { return }
    if ($existing) { $null = Set-AzNetworkSecurityRuleConfig @p } else { $null = Add-AzNetworkSecurityRuleConfig @p }
    Write-Verbose "$verb rule $Name on $($r.Name)."
    $null = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg
    return (Get-NetSecurityRuleInfo -NetworkSecurityGroupId $NetworkSecurityGroupId | Where-Object Name -eq $Name)
}
#endregion

#region Public IPs ------------------------------------------------------------
function Get-NetPublicIpInfo {
    <#
    .SYNOPSIS
        Public IP addresses with what each is attached to. Unattached ones still
        cost money and are flagged.
    #>
    [CmdletBinding()]
    param([Parameter()] [string]$ResourceGroupName)
    $pips = if ($ResourceGroupName) { @(Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName) } else { @(Get-AzPublicIpAddress) }
    foreach ($ip in $pips | Sort-Object ResourceGroupName, Name) {
        $att = ''
        if ($ip.IpConfiguration -and $ip.IpConfiguration.Id) {
            $parts = $ip.IpConfiguration.Id -split '/'
            $att = "$($parts[7] -replace 's$', '') $($parts[8])"
        } elseif ($ip.NatGateway -and $ip.NatGateway.Id) {
            $att = "natGateway $(($ip.NatGateway.Id -split '/')[-1])"
        }
        [pscustomobject]@{
            Name = $ip.Name; ResourceGroupName = $ip.ResourceGroupName; Location = $ip.Location
            Address = "$($ip.IpAddress)"; Sku = "$($ip.Sku.Name)"; Allocation = "$($ip.PublicIpAllocationMethod)"
            Zones = (@($ip.Zones) -join ',')
            AttachedTo = $(if ($att) { $att } else { 'nothing (still billed)' })
            Id = $ip.Id
        }
    }
}

function New-NetPublicIp {
    <#
    .SYNOPSIS
        A Standard, static public IP (zone-redundant when -Zone 1,2,3 is given).
        Returns the existing one untouched if the name is taken.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [string[]]$Zone = @(),
        [Parameter()] [hashtable]$Tags = @{}
    )
    $existing = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "Public IP $Name exists ($($existing.IpAddress))."; return $existing }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create Standard static public IP$(if ($Zone.Count) { " in zones $($Zone -join ',')" })")) { return }
    $p = @{ ResourceGroupName = $ResourceGroupName; Name = $Name; Location = $Location; Sku = 'Standard'; AllocationMethod = 'Static'; Tag = $Tags }
    if ($Zone.Count -gt 0) { $p.Zone = $Zone }
    Write-Verbose "Creating public IP $Name."
    return New-AzPublicIpAddress @p
}
#endregion

#region NAT gateways ----------------------------------------------------------
#   WHY    Azure ends default outbound access for new subnets; a NAT gateway gives
#          a subnet one fixed outbound IP (useful for allow-lists) without public
#          IPs on the VMs.
function Get-NetNatGatewayInfo {
    <#
    .SYNOPSIS
        NAT gateways with their public IPs and the subnets that use them.
    #>
    [CmdletBinding()]
    param()
    foreach ($n in @(Get-AzNatGateway) | Sort-Object ResourceGroupName, Name) {
        [pscustomobject]@{
            Name = $n.Name; ResourceGroupName = $n.ResourceGroupName; Location = $n.Location
            PublicIps = (@($n.PublicIpAddresses | ForEach-Object { ($_.Id -split '/')[-1] }) -join ', ')
            Subnets   = (@($n.Subnets | ForEach-Object { $p = $_.Id -split '/'; "$($p[8])/$($p[10])" }) -join ', ')
            IdleTimeoutMinutes = $n.IdleTimeoutInMinutes
            Id = $n.Id
        }
    }
}

function New-NetNatGateway {
    <#
    .SYNOPSIS
        A NAT gateway with one Standard public IP (created if missing).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [string]$PublicIpName = "$Name-pip",
        [Parameter()] [ValidateRange(4, 120)] [int]$IdleTimeoutMinutes = 4
    )
    $existing = Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "NAT gateway $Name exists."; return $existing }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create NAT gateway with public IP $PublicIpName")) { return }
    $pip = New-NetPublicIp -ResourceGroupName $ResourceGroupName -Name $PublicIpName -Location $Location
    Write-Verbose "Creating NAT gateway $Name."
    return New-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location -Sku Standard -PublicIpAddress $pip -IdleTimeoutInMinutes $IdleTimeoutMinutes
}

function Set-NetSubnetNatGateway {
    <#
    .SYNOPSIS
        Attach a NAT gateway to a subnet, or -Detach it. Outbound traffic from the
        subnet changes source IP at once; open long-lived connections drop.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VirtualNetworkId,
        [Parameter(Mandatory)] [string]$SubnetName,
        [Parameter(ParameterSetName = 'Attach', Mandatory)] [string]$NatGatewayId,
        [Parameter(ParameterSetName = 'Detach', Mandatory)] [switch]$Detach
    )
    $vnet = Get-NetVirtualNetworkObject $VirtualNetworkId
    $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName | Select-Object -First 1
    if (-not $subnet) { throw "Subnet $SubnetName not found on $($vnet.Name)." }
    $current = if ($subnet.NatGateway) { $subnet.NatGateway.Id } else { '' }
    if ($Detach) {
        if (-not $current) { Write-Verbose "$SubnetName has no NAT gateway."; return $subnet }
        if (-not $PSCmdlet.ShouldProcess("$($vnet.Name)/$SubnetName", "Detach NAT gateway $(($current -split '/')[-1])")) { return }
        $subnet.NatGateway = $null
    } else {
        if ($current -eq $NatGatewayId) { Write-Verbose "$SubnetName already uses that NAT gateway."; return $subnet }
        $r = Split-NetResourceId $NatGatewayId
        $nat = Get-AzNatGateway -ResourceGroupName $r.ResourceGroupName -Name $r.Name
        if ($nat.Location -ne $vnet.Location) { throw "The NAT gateway is in $($nat.Location); the VNet is in $($vnet.Location)." }
        if (-not $PSCmdlet.ShouldProcess("$($vnet.Name)/$SubnetName", "Attach NAT gateway $($r.Name)")) { return }
        $subnet.NatGateway = $nat
    }
    Write-Verbose "Updating subnet $SubnetName."
    $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
    return ($vnet.Subnets | Where-Object Name -eq $SubnetName)
}
#endregion

#region VPN -------------------------------------------------------------------
#   GOTCHA A VPN gateway takes 30 to 45 minutes to create and bills from the
#          start (VpnGw1AZ is roughly the price of a small VM, around the clock).
#          It needs a subnet named exactly GatewaySubnet, /27 or larger. Creation
#          is submitted as a job and shows as Updating until it is done.
function Get-NetResourceOfType {
    param([string]$Type)
    return @(Get-AzResource -ResourceType $Type -ErrorAction SilentlyContinue)
}

function Get-NetVpnGatewayInfo {
    <#
    .SYNOPSIS
        Virtual network gateways (VPN and ExpressRoute) with SKU, VNet and public IPs.
    #>
    [CmdletBinding()]
    param()
    foreach ($res in Get-NetResourceOfType 'Microsoft.Network/virtualNetworkGateways' | Sort-Object ResourceGroupName, Name) {
        $g = Get-AzVirtualNetworkGateway -ResourceGroupName $res.ResourceGroupName -Name $res.Name
        $vnet = if ($g.IpConfigurations -and $g.IpConfigurations[0].Subnet) { ($g.IpConfigurations[0].Subnet.Id -split '/')[8] } else { '' }
        $ips = @($g.IpConfigurations | ForEach-Object {
            if ($_.PublicIpAddress) { $pr = Split-NetResourceId $_.PublicIpAddress.Id; (Get-AzPublicIpAddress -ResourceGroupName $pr.ResourceGroupName -Name $pr.Name -ErrorAction SilentlyContinue).IpAddress } })
        [pscustomobject]@{
            Name = $g.Name; ResourceGroupName = $g.ResourceGroupName; Location = $g.Location
            Type = "$($g.GatewayType)"; VpnType = "$($g.VpnType)"; Sku = "$($g.Sku.Name)"; ActiveActive = [bool]$g.ActiveActive
            Bgp = [bool]$g.EnableBgp; VNet = $vnet; PublicIps = ($ips -join ', '); State = "$($g.ProvisioningState)"; Id = $g.Id
        }
    }
}

function Get-NetLocalGatewayInfo {
    <#
    .SYNOPSIS
        Local network gateways: the other end of a site-to-site VPN.
    #>
    [CmdletBinding()]
    param()
    foreach ($res in Get-NetResourceOfType 'Microsoft.Network/localNetworkGateways' | Sort-Object ResourceGroupName, Name) {
        $l = Get-AzLocalNetworkGateway -ResourceGroupName $res.ResourceGroupName -Name $res.Name
        [pscustomobject]@{
            Name = $l.Name; ResourceGroupName = $l.ResourceGroupName; Location = $l.Location
            GatewayIp = "$($l.GatewayIpAddress)"; Fqdn = "$($l.Fqdn)"
            AddressPrefixes = (@($l.LocalNetworkAddressSpace.AddressPrefixes) -join ', '); Id = $l.Id
        }
    }
}

function Get-NetVpnConnectionInfo {
    <#
    .SYNOPSIS
        Gateway connections with their live status and traffic counters.
    #>
    [CmdletBinding()]
    param()
    foreach ($res in Get-NetResourceOfType 'Microsoft.Network/connections' | Sort-Object ResourceGroupName, Name) {
        $c = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $res.ResourceGroupName -Name $res.Name
        [pscustomobject]@{
            Name = $c.Name; ResourceGroupName = $c.ResourceGroupName; Type = "$($c.ConnectionType)"
            Status = "$($c.ConnectionStatus)"
            Gateway = $(if ($c.VirtualNetworkGateway1) { ($c.VirtualNetworkGateway1.Id -split '/')[-1] } else { '' })
            Peer = $(if ($c.LocalNetworkGateway2) { ($c.LocalNetworkGateway2.Id -split '/')[-1] } elseif ($c.VirtualNetworkGateway2) { ($c.VirtualNetworkGateway2.Id -split '/')[-1] } else { '' })
            Protocol = "$($c.ConnectionProtocol)"
            InMB = [math]::Round([double]$c.IngressBytesTransferred / 1MB, 1); OutMB = [math]::Round([double]$c.EgressBytesTransferred / 1MB, 1)
            Id = $c.Id
        }
    }
}

function New-NetVpnGateway {
    <#
    .SYNOPSIS
        A route-based VPN gateway in a VNet. Adds GatewaySubnet if the VNet has
        none (give -GatewaySubnetPrefix, /27 or larger). Submitted as a job:
        returns at once, the gateway shows Updating for 30 to 45 minutes.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$VirtualNetworkId,
        [Parameter()] [string]$GatewaySubnetPrefix,
        [Parameter()] [ValidateSet('VpnGw1AZ', 'VpnGw2AZ', 'VpnGw3AZ', 'VpnGw1', 'VpnGw2')] [string]$Sku = 'VpnGw1AZ'
    )
    $existing = Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "Gateway $Name exists ($($existing.ProvisioningState))."; return $existing }
    $vnet = Get-NetVirtualNetworkObject $VirtualNetworkId
    $gws = $vnet.Subnets | Where-Object Name -eq 'GatewaySubnet' | Select-Object -First 1
    if (-not $gws) {
        if (-not $GatewaySubnetPrefix) { throw "$($vnet.Name) has no GatewaySubnet. Give -GatewaySubnetPrefix (a free /27 inside the VNet's address space)." }
        if ($GatewaySubnetPrefix -notmatch '/(2[0-7]|1\d)$') { throw 'GatewaySubnet must be /27 or larger.' }
    }
    $zones = if ($Sku -like '*AZ') { @('1', '2', '3') } else { @() }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create $Sku VPN gateway in $($vnet.Name) (30 to 45 minutes, billed from the start)")) { return }
    if (-not $gws) {
        $gws = New-NetSubnet -VirtualNetworkId $VirtualNetworkId -Name 'GatewaySubnet' -AddressPrefix $GatewaySubnetPrefix
        $vnet = Get-NetVirtualNetworkObject $VirtualNetworkId
        $gws = $vnet.Subnets | Where-Object Name -eq 'GatewaySubnet' | Select-Object -First 1
    }
    $pip = New-NetPublicIp -ResourceGroupName $ResourceGroupName -Name "$Name-pip" -Location $vnet.Location -Zone $zones
    $ipc = New-AzVirtualNetworkGatewayIpConfig -Name 'gwipconfig1' -SubnetId $gws.Id -PublicIpAddressId $pip.Id
    Write-Verbose "Submitting gateway $Name; it carries on in Azure for 30 to 45 minutes."
    $job = New-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -Name $Name -Location $vnet.Location -IpConfigurations $ipc `
        -GatewayType Vpn -VpnType RouteBased -GatewaySku $Sku -AsJob
    Start-Sleep -Seconds 20
    if ($job.State -eq 'Failed') { throw "Gateway creation failed: $(($job | Receive-Job -ErrorAction SilentlyContinue 2>&1 | Out-String).Trim())" }
    [pscustomobject]@{ Name = $Name; Sku = $Sku; VNet = $vnet.Name; PublicIp = "$Name-pip"; State = 'Creating (30 to 45 minutes)' }
}

function New-NetLocalGateway {
    <#
    .SYNOPSIS
        The other end of a site-to-site VPN: its public IP and the address ranges
        behind it. Returns the existing one untouched if the name is taken.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')] [string]$GatewayIpAddress,
        [Parameter(Mandatory)] [string[]]$AddressPrefix
    )
    foreach ($p in $AddressPrefix) { if (-not (Test-NetCidr $p)) { throw "'$p' is not an IPv4 CIDR." } }
    $existing = Get-AzLocalNetworkGateway -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "Local gateway $Name exists."; return $existing }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create local network gateway $GatewayIpAddress ($($AddressPrefix -join ', '))")) { return }
    Write-Verbose "Creating local gateway $Name."
    return New-AzLocalNetworkGateway -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location -GatewayIpAddress $GatewayIpAddress -AddressPrefix $AddressPrefix
}

function New-NetVpnConnection {
    <#
    .SYNOPSIS
        A site-to-site IPsec connection between a VPN gateway and a local gateway,
        with a pre-shared key (default IKE policy). Returns the existing one untouched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$GatewayId,
        [Parameter(Mandatory)] [string]$LocalGatewayId,
        [Parameter(Mandatory)] [securestring]$SharedKey
    )
    $existing = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "Connection $Name exists ($($existing.ConnectionStatus))."; return $existing }
    $g = Split-NetResourceId $GatewayId; $l = Split-NetResourceId $LocalGatewayId
    $gw = Get-AzVirtualNetworkGateway -ResourceGroupName $g.ResourceGroupName -Name $g.Name
    if ("$($gw.ProvisioningState)" -ne 'Succeeded') { throw "Gateway $($g.Name) is $($gw.ProvisioningState); wait until it is Succeeded." }
    $lng = Get-AzLocalNetworkGateway -ResourceGroupName $l.ResourceGroupName -Name $l.Name
    if (-not $PSCmdlet.ShouldProcess($Name, "Connect $($g.Name) to $($l.Name) (IPsec, pre-shared key)")) { return }
    Write-Verbose "Creating connection $Name."
    $key = [System.Net.NetworkCredential]::new('', $SharedKey).Password
    $null = New-AzVirtualNetworkGatewayConnection -ResourceGroupName $ResourceGroupName -Name $Name -Location $gw.Location `
        -VirtualNetworkGateway1 $gw -LocalNetworkGateway2 $lng -ConnectionType IPsec -SharedKey $key -RoutingWeight 10
    $key = $null
    return (Get-NetVpnConnectionInfo | Where-Object Name -eq $Name)
}
#endregion

Export-ModuleMember -Function @(
    'Get-NetVirtualNetworkInfo'
    'Get-NetSubnetInfo'
    'Get-NetSecurityGroupInfo'
    'Test-NetCidr'
    'Test-NetSubnetPrefix'
    'Get-NetFreeSubnetPrefix'
    'New-NetVirtualNetwork'
    'Set-NetVirtualNetworkDnsServer'
    'Add-NetAddressSpace'
    'New-NetSubnet'
    'Set-NetSubnet'
    'New-NetSecurityGroup'
    'Get-NetSecurityRuleInfo'
    'Set-NetSecurityRule'
    'Get-NetPublicIpInfo'
    'New-NetPublicIp'
    'Get-NetNatGatewayInfo'
    'New-NetNatGateway'
    'Set-NetSubnetNatGateway'
    'Get-NetVpnGatewayInfo'
    'Get-NetLocalGatewayInfo'
    'Get-NetVpnConnectionInfo'
    'New-NetVpnGateway'
    'New-NetLocalGateway'
    'New-NetVpnConnection'
)
