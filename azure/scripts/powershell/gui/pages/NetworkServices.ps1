<#
    Network service pages for Start-AvdGui.ps1: NSGs and their rules, public IPs,
    NAT gateways, VPN. Dot-sourced by the main script; uses its helpers and $Gui.
    Nothing here deletes: a rule is switched off by setting it to Deny, and an
    inbound Allow from the whole internet is refused unless ticked on purpose.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-*/Set-*/Update-* here build or refresh WPF controls. Changes go through the repo scripts, which support -WhatIf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Handlers and OnDone callbacks have fixed signatures.')]
param()

# --- NSGs and rules -----------------------------------------------------------
function New-NsgPage {
    $page = @{ Key = 'NavNsg'; Form = New-Form; Groups = @() }
    $form = $page.Form
    $root = New-PageRoot -Title 'Network security groups' -Lead 'Select an NSG to see its rules, Azure''s defaults included. Add or change a rule below; to turn a rule off, set it to Deny (rules are not removed here). For remote desktop use Generate RDP instead of a standing rule.'
    $page.Grid = New-DataGrid -Height 200
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.Busy) { Invoke-NsgRuleList -Page $pg } }
    $null = $root.Children.Add((New-TableCard -Title 'NSGs' -Grid $page.Grid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-NsgList -Page $pg }))))
    $page.RuleGrid = New-DataGrid -Height 240
    $page.RuleGrid.SelectionMode = 'Single'
    $actions = @(
        @{ Text = 'Edit in the form below'; Context = $page; Handler = { param($pg) Update-NsgRuleForm -Page $pg } }
        @{ Text = 'Set to Deny';            Context = $page; Handler = { param($pg) Invoke-NsgRuleDeny -Page $pg }; ToolTip = 'Keeps the rule, stops it allowing anything' }
    )
    Set-GridRowMenu -Grid $page.RuleGrid -Items $actions
    Add-ControlHandler -Control $page.RuleGrid -EventName DoubleClick -Context $page -Handler { param($pg) Update-NsgRuleForm -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Rules of the selected NSG' -Grid $page.RuleGrid -Tools @((New-MenuButton -Items $actions)) -Note 'Default rules (65000 and up) are Azure''s and cannot be changed; a rule with a lower number wins.'))

    $rule = New-FormSection -Form $form -Title 'Add or change a rule' -Subtitle 'Same name = change that rule. Separate several addresses or ports with commas.' -Fields @(
        @{ Name = 'RuleName'; Label = 'Name'; Required = $true }
        @{ Name = 'RulePriority'; Label = 'Priority (100 to 4096, lower wins)'; Type = 'int'; Default = 300; Required = $true }
        @{ Name = 'RuleDirection'; Label = 'Direction'; Type = 'combo'; Default = 'Inbound'; Options = @('Inbound', 'Outbound') }
        @{ Name = 'RuleAccess'; Label = 'Access'; Type = 'combo'; Default = 'Allow'; Options = @('Allow', 'Deny') }
        @{ Name = 'RuleProtocol'; Label = 'Protocol'; Type = 'combo'; Default = 'Tcp'; Options = @('Tcp', 'Udp', 'Icmp', '*') }
        @{ Name = 'RulePorts'; Label = 'Destination ports'; Required = $true; Default = '443' }
        @{ Name = 'RuleSource'; Label = 'Source addresses or tags'; Default = 'VirtualNetwork'; Help = 'IP, CIDR or a tag such as VirtualNetwork, AzureLoadBalancer.' }
        @{ Name = 'RuleDestination'; Label = 'Destination addresses or tags'; Default = '*' }
        @{ Name = 'RuleDescription'; Label = 'Description'; Span = 2 }
        @{ Name = 'RuleInternet'; Label = 'I mean it: allow this inbound from the whole internet'; Type = 'check'; Default = $false; Span = 2 }
    )
    $null = $rule.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Save rule' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-NsgRuleSave -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-NsgRuleSave -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Use my public IP as source' -Style 'GhostButton' -Context $page -OnClick { param($pg) Invoke-NsgMyIp -Page $pg }))))
    $null = $root.Children.Add($rule)

    $create = New-FormSection -Form $form -Title 'Create an NSG' -Subtitle 'Default rules only. Attach it to a subnet on the Virtual networks page.' -Fields @(
        @{ Name = 'NsgRg'; Label = 'Resource group'; Type = 'combo'; Required = $true }
        @{ Name = 'NsgName'; Label = 'Name'; Required = $true }
    )
    $Gui.RgCombos.Add($form.Controls['NsgRg'])
    $null = $create.Child.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Create NSG' -Context $page -OnClick { param($pg) Invoke-NsgCreate -Page $pg }))))
    $null = $root.Children.Add($create)
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Update-ResourceGroupList -Context $pg -OnDone { param($p) Invoke-NsgList -Page $p } } }
    $page.Root = $root
    return $page
}

function Invoke-NsgList {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List NSGs' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        Get-NetSecurityGroupInfo
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Groups = @($result)
        $pg.RuleGrid.ItemsSource = $null
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Groups -Columns @('Name', 'ResourceGroupName', 'Location', 'Rules', 'Subnets', 'Nics')).DefaultView
    }
}

function Get-NsgSelected {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { return $null }
    return ($Page.Groups | Where-Object { $_.Name -eq $sel[0].Name -and $_.ResourceGroupName -eq $sel[0].ResourceGroupName } | Select-Object -First 1)
}

function Invoke-NsgRuleList {
    param([hashtable]$Page)
    $n = Get-NsgSelected -Page $Page
    if (-not $n) { return }
    Start-Work -Name "Rules of $($n.Name)" -Argument @{ Id = $n.Id } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-NetSecurityRuleInfo -NetworkSecurityGroupId $Job.Id -IncludeDefault
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.RuleGrid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('Priority', 'Name', 'Direction', 'Access', 'Protocol', 'Source', 'Destination', 'Ports', 'Description', 'Default')).DefaultView
    }
}

function Update-NsgRuleForm {
    param([hashtable]$Page)
    $r = Get-GridSelection $Page.RuleGrid
    if ($r.Count -ne 1) { return }
    if ($r[0].Default -eq 'True') { Show-Message 'Default rules cannot be changed. Add a rule with a lower number to override one.' 'Rule' 'Information'; return }
    $f = $Page.Form
    Set-FormValue $f 'RuleName' $r[0].Name; Set-FormValue $f 'RulePriority' $r[0].Priority; Set-FormValue $f 'RuleDirection' $r[0].Direction
    Set-FormValue $f 'RuleAccess' $r[0].Access; Set-FormValue $f 'RuleProtocol' $r[0].Protocol; Set-FormValue $f 'RulePorts' $r[0].Ports
    Set-FormValue $f 'RuleSource' $r[0].Source; Set-FormValue $f 'RuleDestination' $r[0].Destination; Set-FormValue $f 'RuleDescription' $r[0].Description
    Set-FormValue $f 'RuleInternet' $false
    $f.Controls['RuleName'].BringIntoView()
}

function Get-NsgRuleParameter {
    param([hashtable]$Page, [hashtable]$Nsg)
    $f = $Page.Form
    $p = @{
        SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $Nsg.ResourceGroupName; NetworkSecurityGroupName = $Nsg.Name
        Name = (Get-FormValue $f 'RuleName'); Priority = (Get-FormValue $f 'RulePriority'); Direction = (Get-FormValue $f 'RuleDirection')
        Access = (Get-FormValue $f 'RuleAccess'); Protocol = (Get-FormValue $f 'RuleProtocol')
        DestinationPortRange = (Split-CommaList (Get-FormValue $f 'RulePorts'))
        SourceAddressPrefix = (Split-CommaList (Get-FormValue $f 'RuleSource'))
        DestinationAddressPrefix = (Split-CommaList (Get-FormValue $f 'RuleDestination'))
    }
    $d = Get-FormValue $f 'RuleDescription'; if ($d) { $p.Description = $d }
    if (Get-FormValue $f 'RuleInternet') { $p.AllowInternetSource = $true }
    return $p
}

function Invoke-NsgRuleSave {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $n = Get-NsgSelected -Page $Page
    if (-not $n) { Show-Message 'Select the NSG first.' 'Rule' 'Warning'; return }
    if (-not (Test-FormRequired -Form $Page.Form -Only @('RuleName', 'RulePriority', 'RulePorts'))) { return }
    $p = Get-NsgRuleParameter -Page $Page -Nsg $n
    Invoke-RepoScript -Name "Rule $($p.Name) on $($n.Name)" -Path $Gui.Scripts.NetRule -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Invoke-NsgRuleList -Page $pg }
    }
}

function Invoke-NsgRuleDeny {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $n = Get-NsgSelected -Page $Page
    $r = Get-GridSelection $Page.RuleGrid
    if (-not $n -or $r.Count -ne 1) { Show-Message 'Select one rule.' 'Rule' 'Warning'; return }
    if ($r[0].Default -eq 'True') { Show-Message 'Default rules cannot be changed.' 'Rule' 'Information'; return }
    if ($r[0].Access -eq 'Deny') { Show-Message "$($r[0].Name) already denies." 'Rule' 'Information'; return }
    $p = @{
        SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $n.ResourceGroupName; NetworkSecurityGroupName = $n.Name
        Name = $r[0].Name; Priority = [int]$r[0].Priority; Direction = $r[0].Direction; Access = 'Deny'; Protocol = $r[0].Protocol
        SourceAddressPrefix = (Split-CommaList $r[0].Source); DestinationAddressPrefix = (Split-CommaList $r[0].Destination); DestinationPortRange = (Split-CommaList $r[0].Ports)
    }
    if ($r[0].Description) { $p.Description = $r[0].Description }
    Invoke-RepoScript -Name "Set $($r[0].Name) to Deny" -Path $Gui.Scripts.NetRule -Params $p -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Invoke-NsgRuleList -Page $pg }
    }
}

function Invoke-NsgMyIp {
    param([hashtable]$Page)
    Start-Work -Name 'Find my public IP' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        Get-ServerCallerIp
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $ip = "$(@($result)[-1])".Trim()
        if ($ip) { Set-FormValue $pg.Form 'RuleSource' $ip; Write-GuiLog "Your public IP is $ip." 'info' }
    }
}

function Invoke-NsgCreate {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form -Only @('NsgRg', 'NsgName'))) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-FormValue $Page.Form 'NsgRg'); Name = (Get-FormValue $Page.Form 'NsgName') }
    Invoke-RepoScript -Name "Create NSG $($p.Name)" -Path $Gui.Scripts.NetNsgNew -Params $p -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Invoke-NsgList -Page $pg }
    }
}

# --- Public IPs ---------------------------------------------------------------
function New-PublicIpPage {
    $page = @{ Key = 'NavPip'; Form = New-Form }
    $root = New-PageRoot -Title 'Public IP addresses' -Lead 'Every public IP and what it is attached to. One attached to nothing still bills; delete those in the portal once you are sure.'
    $page.Grid = New-DataGrid -Height 300
    $null = $root.Children.Add((New-TableCard -Title 'Public IPs' -Grid $page.Grid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-PipList -Page $pg }))))
    $create = New-FormSection -Form $page.Form -Title 'Create a public IP' -Subtitle 'Standard, static. Most of the time a NAT gateway (outbound) or Generate RDP (inbound) is the better answer.' -Fields @(
        @{ Name = 'PipRg'; Label = 'Resource group'; Type = 'combo'; Required = $true }
        @{ Name = 'PipName'; Label = 'Name'; Required = $true }
        @{ Name = 'PipZones'; Label = 'Zone-redundant (zones 1, 2, 3)'; Type = 'check'; Default = $true }
    )
    $Gui.RgCombos.Add($page.Form.Controls['PipRg'])
    $null = $create.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create public IP' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-PipCreate -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-PipCreate -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($create)
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Update-ResourceGroupList -Context $pg -OnDone { param($p) Invoke-PipList -Page $p } } }
    $page.Root = $root
    return $page
}

function Invoke-PipList {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List public IPs' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        Get-NetPublicIpInfo
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $rows = @($result)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $rows -Columns @('Name', 'Address', 'AttachedTo', 'ResourceGroupName', 'Location', 'Sku', 'Allocation', 'Zones')).DefaultView
        $idle = @($rows | Where-Object { $_.AttachedTo -like 'nothing*' })
        if ($idle.Count -gt 0) { Write-GuiLog "$($idle.Count) public IP(s) attached to nothing and still billed: $(@($idle | ForEach-Object Name) -join ', ')." 'warn' }
    }
}

function Invoke-PipCreate {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form)) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-FormValue $Page.Form 'PipRg'); Name = (Get-FormValue $Page.Form 'PipName') }
    if (Get-FormValue $Page.Form 'PipZones') { $p.Zone = @('1', '2', '3') }
    Invoke-RepoScript -Name "Create public IP $($p.Name)" -Path $Gui.Scripts.NetPip -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Invoke-PipList -Page $pg }
    }
}

# --- NAT gateways -------------------------------------------------------------
function New-NatPage {
    $page = @{ Key = 'NavNat'; Form = New-Form; Nats = @() }
    $form = $page.Form
    $root = New-PageRoot -Title 'NAT gateways' -Lead 'One fixed outbound IP for whole subnets, without public IPs on the VMs. Azure is ending default outbound access for new subnets, so new networks need this (or a firewall) to reach the internet.'
    $page.Grid = New-DataGrid -Height 200
    $null = $root.Children.Add((New-TableCard -Title 'NAT gateways' -Grid $page.Grid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-NatLoad -Page $pg }))))
    $create = New-FormSection -Form $form -Title 'Create a NAT gateway' -Subtitle 'With a new Standard public IP. Bills hourly plus data processed.' -Fields @(
        @{ Name = 'NatRg'; Label = 'Resource group'; Type = 'combo'; Required = $true; Help = 'Its region must match the VNet.' }
        @{ Name = 'NatName'; Label = 'Name'; Required = $true }
        @{ Name = 'NatSubnet'; Label = 'Attach to subnet (optional)'; Type = 'combo'; Span = 2 }
    )
    $Gui.RgCombos.Add($form.Controls['NatRg'])
    $null = $create.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create NAT gateway' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-NatCreate -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-NatCreate -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($create)
    $attach = New-FormSection -Form $form -Title 'Attach or detach' -Subtitle 'Outbound connections from the subnet change source IP at once; long-lived ones drop.' -Fields @(
        @{ Name = 'AttSubnet'; Label = 'Subnet'; Type = 'combo'; Required = $true; Span = 2 }
        @{ Name = 'AttNat'; Label = 'NAT gateway'; Type = 'combo'; Span = 2 }
    )
    $null = $attach.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Attach' -Style 'PrimaryButton' -Context @{ Page = $page; Detach = $false } -OnClick { param($c) Invoke-NatAttach -Page $c.Page -Detach:$c.Detach }),
        (New-Button -Text 'Detach from subnet' -Context @{ Page = $page; Detach = $true } -OnClick { param($c) Invoke-NatAttach -Page $c.Page -Detach:$c.Detach }))))
    $null = $root.Children.Add($attach)
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Update-ResourceGroupList -Context $pg -OnDone { param($p) Start-NatLoad -Page $p } } }
    $page.Root = $root
    return $page
}

function Start-NatLoad {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List NAT gateways' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        $subnets = @(Get-NetSubnetInfo | ForEach-Object { [pscustomobject]@{ Value = $_.Id; Label = "$($_.VirtualNetwork)/$($_.Name)  $($_.AddressPrefix)" } })
        [pscustomobject]@{ Nats = @(Get-NetNatGatewayInfo); Subnets = $subnets }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Nats = @($r.Nats)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Nats -Columns @('Name', 'ResourceGroupName', 'Location', 'PublicIps', 'Subnets', 'IdleTimeoutMinutes')).DefaultView
        $sub = @($r.Subnets | ForEach-Object { @{ Value = $_.Value; Label = $_.Label } })
        Add-ComboOption -Combo $pg.Form.Controls['NatSubnet'] -Options (@(@{ Value = ''; Label = 'None' }) + $sub) -Default (Get-ComboValue $pg.Form.Controls['NatSubnet'])
        Add-ComboOption -Combo $pg.Form.Controls['AttSubnet'] -Options $sub -Default (Get-ComboValue $pg.Form.Controls['AttSubnet'])
        Add-ComboOption -Combo $pg.Form.Controls['AttNat'] -Options @($pg.Nats | ForEach-Object { @{ Value = $_.Id; Label = "$($_.Name)  ($($_.Location))" } }) -Default (Get-ComboValue $pg.Form.Controls['AttNat'])
    }
}

function Invoke-NatCreate {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form -Only @('NatRg', 'NatName'))) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-FormValue $Page.Form 'NatRg'); Name = (Get-FormValue $Page.Form 'NatName') }
    $s = Get-FormValue $Page.Form 'NatSubnet'; if ($s) { $p.SubnetId = @($s) }
    Invoke-RepoScript -Name "Create NAT gateway $($p.Name)" -Path $Gui.Scripts.NetNat -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-NatLoad -Page $pg }
    }
}

function Invoke-NatAttach {
    param([hashtable]$Page, [switch]$Detach)
    if (-not (Test-SignedIn)) { return }
    $s = Get-FormValue $Page.Form 'AttSubnet'
    if (-not $s) { Show-Message 'Pick the subnet.' 'NAT' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; SubnetId = $s }
    if ($Detach) { $p.Detach = $true }
    else {
        $n = Get-FormValue $Page.Form 'AttNat'
        if (-not $n) { Show-Message 'Pick the NAT gateway.' 'NAT' 'Warning'; return }
        $p.NatGatewayId = $n
    }
    Invoke-RepoScript -Name $(if ($Detach) { 'Detach NAT gateway' } else { 'Attach NAT gateway' }) -Path $Gui.Scripts.NetNatSubnet -Params $p -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-NatLoad -Page $pg }
    }
}

# --- VPN ----------------------------------------------------------------------
function New-VpnPage {
    $page = @{ Key = 'NavVpn'; Form = New-Form; Gateways = @() }
    $form = $page.Form
    $root = New-PageRoot -Title 'VPN' -Lead 'Site-to-site VPN: gateways, connections with live status and traffic, and the on-premises sites. A gateway takes 30 to 45 minutes to create and bills from the start.'
    $page.Grid = New-DataGrid -Height 150
    $null = $root.Children.Add((New-TableCard -Title 'Gateways' -Grid $page.Grid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-VpnLoad -Page $pg }))))
    $page.ConnGrid = New-DataGrid -Height 150
    $null = $root.Children.Add((New-TableCard -Title 'Connections' -Grid $page.ConnGrid -Note 'Status Connected needs both ends configured with the same key; NotConnected usually means the device side, a key mismatch, or an IKE policy mismatch.'))
    $page.SiteGrid = New-DataGrid -Height 130
    $null = $root.Children.Add((New-TableCard -Title 'Sites (local network gateways)' -Grid $page.SiteGrid))

    $gw = New-FormSection -Form $form -Title 'Create a VPN gateway' -Subtitle 'Route-based. Adds GatewaySubnet when the VNet has none. VpnGw1AZ costs about as much as a small VM running all month.' -Fields @(
        @{ Name = 'GwRg'; Label = 'Resource group'; Type = 'combo'; Required = $true }
        @{ Name = 'GwName'; Label = 'Name'; Required = $true; Default = 'vpngw-01' }
        @{ Name = 'GwVnet'; Label = 'Virtual network'; Type = 'combo'; Required = $true; Span = 2 }
        @{ Name = 'GwSubnet'; Label = 'GatewaySubnet prefix (if the VNet has none; /27 or larger)' }
        @{ Name = 'GwSku'; Label = 'SKU'; Type = 'combo'; Default = 'VpnGw1AZ'; Options = @('VpnGw1AZ', 'VpnGw2AZ', 'VpnGw3AZ', 'VpnGw1', 'VpnGw2') }
    )
    $Gui.RgCombos.Add($form.Controls['GwRg'])
    $null = $gw.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create gateway' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-VpnGatewayCreate -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-VpnGatewayCreate -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($gw)

    $site = New-FormSection -Form $form -Title 'Connect a site' -Subtitle 'A local gateway for the site and an IPsec connection with a pre-shared key. Put the same key and the gateway''s public IP on the on-premises device.' -Fields @(
        @{ Name = 'SiteGateway'; Label = 'Gateway (must show Succeeded)'; Type = 'combo'; Required = $true; Span = 2 }
        @{ Name = 'SiteRg'; Label = 'Resource group'; Type = 'combo'; Required = $true }
        @{ Name = 'SiteName'; Label = 'Site name'; Required = $true; Help = 'Names lng-<site> and cn-<site>.' }
        @{ Name = 'SiteIp'; Label = 'Site public IP'; Required = $true }
        @{ Name = 'SitePrefixes'; Label = 'Site address ranges (comma separated)'; Required = $true }
        @{ Name = 'SiteKey'; Label = 'Pre-shared key'; Type = 'password' }
        @{ Name = 'SiteKeyConfirm'; Label = 'Pre-shared key again'; Type = 'password' }
    )
    $Gui.RgCombos.Add($form.Controls['SiteRg'])
    $null = $site.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Connect site' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-VpnSiteCreate -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-VpnSiteCreate -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($site)
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Update-ResourceGroupList -Context $pg -OnDone { param($p) Start-VpnLoad -Page $p } } }
    $page.Root = $root
    return $page
}

function Start-VpnLoad {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'Load VPN' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{
            Gateways = @(Get-NetVpnGatewayInfo); Connections = @(Get-NetVpnConnectionInfo); Sites = @(Get-NetLocalGatewayInfo)
            VNets = @(Get-NetVirtualNetworkInfo | ForEach-Object { [pscustomobject]@{ Value = $_.Id; Label = "$($_.Name)  ($($_.ResourceGroupName), $($_.Location), $($_.AddressSpace))" } })
        }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Gateways = @($r.Gateways)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Gateways -Columns @('Name', 'State', 'Sku', 'VNet', 'PublicIps', 'Type', 'VpnType', 'ActiveActive', 'Bgp', 'ResourceGroupName')).DefaultView
        $pg.ConnGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Connections) -Columns @('Name', 'Status', 'Gateway', 'Peer', 'Type', 'Protocol', 'InMB', 'OutMB', 'ResourceGroupName')).DefaultView
        $pg.SiteGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Sites) -Columns @('Name', 'GatewayIp', 'AddressPrefixes', 'Fqdn', 'ResourceGroupName', 'Location')).DefaultView
        Add-ComboOption -Combo $pg.Form.Controls['GwVnet'] -Options @($r.VNets | ForEach-Object { @{ Value = $_.Value; Label = $_.Label } }) -Default (Get-ComboValue $pg.Form.Controls['GwVnet'])
        Add-ComboOption -Combo $pg.Form.Controls['SiteGateway'] -Options @($pg.Gateways | ForEach-Object { @{ Value = $_.Id; Label = "$($_.Name)  ($($_.State), $($_.Sku))" } }) -Default (Get-ComboValue $pg.Form.Controls['SiteGateway'])
    }
}

function Invoke-VpnGatewayCreate {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form -Only @('GwRg', 'GwName', 'GwVnet'))) { return }
    $f = $Page.Form
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-FormValue $f 'GwRg'); Name = (Get-FormValue $f 'GwName'); VirtualNetworkId = (Get-FormValue $f 'GwVnet'); Sku = (Get-FormValue $f 'GwSku') }
    $gs = Get-FormValue $f 'GwSubnet'; if ($gs) { $p.GatewaySubnetPrefix = $gs }
    Invoke-RepoScript -Name "Create VPN gateway $($p.Name)" -Path $Gui.Scripts.NetVpnGateway -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-VpnLoad -Page $pg }
    }
}

function Invoke-VpnSiteCreate {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $f = $Page.Form
    if (-not (Test-FormRequired -Form $f -Only @('SiteGateway', 'SiteRg', 'SiteName', 'SiteIp', 'SitePrefixes'))) { return }
    $k1 = $f.Controls['SiteKey']; $k2 = $f.Controls['SiteKeyConfirm']
    if ($k1.SecurePassword.Length -lt 8) { Show-Message 'The pre-shared key needs at least 8 characters.' 'VPN' 'Warning'; return }
    if ($k1.Password -ne $k2.Password) { Show-Message 'The two keys do not match.' 'VPN' 'Warning'; return }
    $p = @{
        SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-FormValue $f 'SiteRg'); GatewayId = (Get-FormValue $f 'SiteGateway')
        SiteName = (Get-FormValue $f 'SiteName'); SiteIpAddress = (Get-FormValue $f 'SiteIp'); SiteAddressPrefix = (Split-CommaList (Get-FormValue $f 'SitePrefixes'))
        SharedKey = $k1.SecurePassword
    }
    Invoke-RepoScript -Name "Connect site $($p.SiteName)" -Path $Gui.Scripts.NetVpnSite -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { $pg.Form.Controls['SiteKey'].Clear(); $pg.Form.Controls['SiteKeyConfirm'].Clear(); Start-VpnLoad -Page $pg }
    }
}
