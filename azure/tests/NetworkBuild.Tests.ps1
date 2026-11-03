BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'NetworkBuild' 'NetworkBuild.psd1'
}

Describe 'NetworkBuild module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'imports and exports the expected functions' {
        Import-Module $script:ManifestPath -Force
        $expected = @('Get-NetVirtualNetworkInfo', 'Get-NetSubnetInfo', 'Get-NetSecurityGroupInfo', 'Test-NetCidr',
            'New-NetVirtualNetwork', 'Set-NetVirtualNetworkDnsServer', 'Add-NetAddressSpace', 'New-NetSubnet', 'Set-NetSubnet', 'New-NetSecurityGroup')
        $actual = (Get-Command -Module NetworkBuild).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }
    It 'every state-changing function supports -WhatIf' {
        Import-Module $script:ManifestPath -Force
        foreach ($name in (Get-Command -Module NetworkBuild | Where-Object { $_.Verb -in 'New', 'Set', 'Add' }).Name) {
            (Get-Command $name).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$name changes state"
        }
    }
    It 'never deletes' {
        (Get-Content (Join-Path (Split-Path $script:ManifestPath) 'NetworkBuild.psm1') -Raw) | Should -Not -Match 'Remove-Az'
    }
    Context 'Test-NetCidr' {
        BeforeAll { Import-Module $script:ManifestPath -Force }
        It 'accepts 10.10.0.0/16'  { Test-NetCidr '10.10.0.0/16' | Should -BeTrue }
        It 'rejects 10.10.0.0'     { Test-NetCidr '10.10.0.0' | Should -BeFalse }
        It 'rejects 300.1.1.0/24'  { Test-NetCidr '300.1.1.0/24' | Should -BeFalse }
        It 'rejects /33'           { Test-NetCidr '10.0.0.0/33' | Should -BeFalse }
    }
}

Describe 'Set-NetSecurityRule safety' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force }
    It 'refuses an inbound Allow from <_> without -AllowInternetSource' -ForEach '*', 'Internet', '0.0.0.0/0', 'Any' {
        { Set-NetSecurityRule -NetworkSecurityGroupId '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/n' -Name r1 -Priority 200 -Direction Inbound -Access Allow -SourceAddressPrefix $_ -DestinationPortRange 3389 } |
            Should -Throw '*whole internet*'
    }
    It 'has no remove path: rules are switched off with Deny' {
        $src = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'NetworkBuild' 'NetworkBuild.psm1') -Raw
        $src | Should -Not -Match 'Remove-AzNetworkSecurityRuleConfig'
        $src | Should -Not -Match 'Remove-Az'
    }
    It 'every manifest export is exported' {
        $m = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'NetworkBuild' 'NetworkBuild.psd1'
        $actual = (Get-Command -Module NetworkBuild).Name
        foreach ($f in (Import-PowerShellDataFile $m).FunctionsToExport) { $actual | Should -Contain $f }
    }
}

Describe 'Subnet address maths' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force
        $script:Taken = @{ 'snet-avd' = '10.10.1.0/24'; 'GatewaySubnet' = '10.10.255.0/27' }
    }
    It 'accepts a free /24 inside the space' { @(Test-NetSubnetPrefix -Prefix '10.10.2.0/24' -AddressSpace '10.10.0.0/16' -Existing $script:Taken).Count | Should -Be 0 }
    It 'refuses a prefix outside the space' { (Test-NetSubnetPrefix -Prefix '10.20.2.0/24' -AddressSpace '10.10.0.0/16') -join ' ' | Should -Match 'outside' }
    It 'refuses an overlap and names the subnet' { (Test-NetSubnetPrefix -Prefix '10.10.1.128/25' -AddressSpace '10.10.0.0/16' -Existing $script:Taken) -join ' ' | Should -Match 'overlaps subnet snet-avd' }
    It 'refuses host bits and suggests the network' { (Test-NetSubnetPrefix -Prefix '10.10.2.5/24' -AddressSpace '10.10.0.0/16') -join ' ' | Should -Match '10\.10\.2\.0/24' }
    It 'refuses smaller than /29' { (Test-NetSubnetPrefix -Prefix '10.10.2.0/30' -AddressSpace '10.10.0.0/16') -join ' ' | Should -Match '/29' }
    It 'refuses junk' { (Test-NetSubnetPrefix -Prefix '10.10.2' -AddressSpace '10.10.0.0/16') -join ' ' | Should -Match 'not a CIDR' }
    It 'accepts a second address space' { @(Test-NetSubnetPrefix -Prefix '10.30.0.0/24' -AddressSpace '10.10.0.0/16, 10.30.0.0/16').Count | Should -Be 0 }
    It 'suggests the next /24 after the subnets in use' { Get-NetFreeSubnetPrefix -AddressSpace '10.10.0.0/16' -Used '10.10.1.0/24' | Should -Be '10.10.2.0/24' }
    It 'lists the rest after it, then the gaps before it' {
        $all = @(Get-NetFreeSubnetPrefix -AddressSpace '10.10.0.0/22' -Used '10.10.1.0/24' -All)
        $all | Should -Be @('10.10.2.0/24', '10.10.3.0/24', '10.10.0.0/24')
    }
    It 'falls back to a gap when nothing is free after' { Get-NetFreeSubnetPrefix -AddressSpace '10.10.0.0/22' -Used '10.10.3.0/24' | Should -Be '10.10.0.0/24' }
    It 'skips a block partly used by a smaller subnet' { Get-NetFreeSubnetPrefix -AddressSpace '10.10.0.0/22' -Used '10.10.0.0/24', '10.10.1.64/26' | Should -Be '10.10.2.0/24' }
    It 'says plainly when a prefix already exists' { (Test-NetSubnetPrefix -Prefix '10.10.1.0/24' -AddressSpace '10.10.0.0/16' -Existing $script:Taken) -join ' ' | Should -Match 'already exists: subnet snet-avd' }
    It 'returns nothing when the space is full' { Get-NetFreeSubnetPrefix -AddressSpace '10.10.0.0/24' -Used '10.10.0.0/24' | Should -BeNullOrEmpty }
}
