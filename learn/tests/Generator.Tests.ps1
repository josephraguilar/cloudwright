BeforeDiscovery {
    Import-Module (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'MsScripter') 'MsScripter.psd1') -Force
    # Every task gets an automatic one-liner golden file built from its own Defaults/Examples/Options.
    $AllTasks = @(Get-MsTaskCatalog -CatalogRoot (Join-Path (Join-Path $PSScriptRoot '..') 'catalog') -Strict | Where-Object Kind -eq 'Task' | ForEach-Object { @{ Id = $_.Id } })
    $AllPaths = @(Get-MsTaskCatalog -CatalogRoot (Join-Path (Join-Path $PSScriptRoot '..') 'catalog') -Strict | Where-Object Kind -eq 'Path' | ForEach-Object { @{ Id = $_.Id } })
    # Hand-written cases with specific answers and the Explained style.
    $Cases = @(
        @{ Name = 'resource-group';          Tasks = @('azure.create.resource-group');  Answers = @{ Name = 'rg-avd-lab'; Location = 'eastus2'; Tags = @{ env = 'lab'; owner = "o'brien" } } }
        @{ Name = 'resource-group-no-tags';  Tasks = @('azure.create.resource-group');  Answers = @{ Name = 'rg-avd-lab'; Location = 'eastus2' } }
        @{ Name = 'set-subscription';        Tasks = @('azure.context.set-subscription'); Answers = @{ SubscriptionId = '00000000-0000-0000-0000-000000000001' } }
        @{ Name = 'new-vnet';                Tasks = @('azure.network.new-vnet');       Answers = @{ ResourceGroupName = 'rg-avd-lab'; Location = 'eastus2'; VNetName = 'vnet-avd-lab'; AddressPrefix = '10.10.0.0/16'; SubnetName = 'snet-hosts'; SubnetPrefix = '10.10.1.0/24' } }
        @{ Name = 'new-security-group';      Tasks = @('m365.groups.new-security-group'); Answers = @{ DisplayName = 'AVD Users - Lab'; MailNickname = 'avd-users-lab' } }
        @{ Name = 'path-rg-and-network';     Tasks = @('azure.create.resource-group', 'azure.network.new-vnet'); Share = @{ ResourceGroupName = 'Name' }
           Answers = @{ Name = 'rg-avd-lab'; Location = 'eastus2'; VNetName = 'vnet-avd-lab'; AddressPrefix = '10.10.0.0/16'; SubnetName = 'snet-hosts'; SubnetPrefix = '10.10.1.0/24' } }
        # One-liner style (the default in the UI)
        @{ Name = 'oneliner-resource-group';  Style = 'OneLiner'; Tasks = @('azure.create.resource-group');  Answers = @{ Name = 'rg-avd-lab'; Location = 'eastus2'; Tags = @{ env = 'lab' } } }
        @{ Name = 'oneliner-new-vnet';        Style = 'OneLiner'; Tasks = @('azure.network.new-vnet');       Answers = @{ ResourceGroupName = 'rg-avd-lab'; Location = 'eastus2'; VNetName = 'vnet-avd-lab'; AddressPrefix = '10.10.0.0/16'; SubnetName = 'snet-hosts'; SubnetPrefix = '10.10.1.0/24' } }
        @{ Name = 'oneliner-security-group';  Style = 'OneLiner'; Tasks = @('m365.groups.new-security-group'); Answers = @{ DisplayName = 'AVD Users - Lab'; MailNickname = 'avd-users-lab' } }
        @{ Name = 'oneliner-set-subscription'; Style = 'OneLiner'; Tasks = @('azure.context.set-subscription'); Answers = @{ SubscriptionId = '00000000-0000-0000-0000-000000000001' } }
        @{ Name = 'oneliner-path-with-extras'; Style = 'OneLiner'; WithContext = $true; WithVerify = $true; WithRollback = $true; Tasks = @('azure.create.resource-group', 'azure.network.new-vnet'); Share = @{ ResourceGroupName = 'Name' }
           Answers = @{ Name = 'rg-avd-lab'; Location = 'eastus2'; VNetName = 'vnet-avd-lab'; AddressPrefix = '10.10.0.0/16'; SubnetName = 'snet-hosts'; SubnetPrefix = '10.10.1.0/24' } }
    )
}
BeforeAll {
    Import-Module (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'MsScripter') 'MsScripter.psd1') -Force
    $script:CatalogRoot = Join-Path (Join-Path $PSScriptRoot '..') 'catalog'
    $script:Golden = Join-Path $PSScriptRoot 'golden'
    $script:Date = Get-Date '2026-01-01'
    $script:Context = @{ SubscriptionName = 'Contoso Lab'; SubscriptionId = '00000000-0000-0000-0000-000000000001'; TenantId = '00000000-0000-0000-0000-00000000aaaa' }

    function New-SampleAnswers($definition) {
        # Deterministic sample answers: Default, else first Option, else Example, else a generated value. Bool is $true so When-gated steps render.
        $a = @{}
        foreach ($f in @($definition.Fields)) {
            if ($f.Type -in 'Secret', 'Reference') { continue }
            $v = $null
            switch ($f.Type) {
                'Bool'        { $v = $true }
                'TrueFalse'   { $v = if ($f.ContainsKey('Default')) { [bool]$f.Default } else { $true } }
                'Int'         { $v = if ($f.ContainsKey('Default')) { $f.Default } elseif ($f.ContainsKey('Example')) { $f.Example } else { '10' } }
                'Hashtable'   { $v = @{ env = 'lab' } }
                'MultiChoice' {
                    if ($f.ContainsKey('Options')) { $v = @(@($f.Options) | Select-Object -First 2 | ForEach-Object { if ($_ -is [hashtable]) { $_.Value } else { "$_" } }) }
                    elseif ($f.ContainsKey('Example')) { $v = @($f.Example -split ',' | ForEach-Object { $_.Trim() }) }
                    else { $v = @('sample-one', 'sample-two') }
                }
                default {
                    if ($f.ContainsKey('Default') -and "$($f.Default)" -ne '') { $v = $f.Default }
                    elseif ($f.ContainsKey('Options')) { $o = @($f.Options)[0]; $v = if ($o -is [hashtable]) { $o.Value } else { "$o" } }
                    elseif ($f.ContainsKey('Example')) { $v = $f.Example }
                    else { $v = "sample-$($f.Name.ToLowerInvariant())" }
                }
            }
            if ($null -ne $v -and "$v" -ne '') { $a[$f.Name] = $v }
        }
        return $a
    }
    function Invoke-Case($case) {
        $tasks = foreach ($id in $case.Tasks) { Get-MsTask -Id $id -CatalogRoot $script:CatalogRoot }
        $share = if ($case.ContainsKey('Share')) { $case.Share } else { @{} }
        $style = if ($case.ContainsKey('Style')) { $case.Style } else { 'Explained' }
        $extra = @{}
        foreach ($k in 'WithContext', 'WithVerify', 'WithRollback') { if ($case.ContainsKey($k)) { $extra[$k] = $case[$k] } }
        New-MsScript -Task @($tasks) -Answers $case.Answers -Context $script:Context -Share $share -Date $script:Date -Style $style @extra
    }
}
Describe 'Every catalog task renders as one-liners' {
    It '<Id>' -ForEach $AllTasks {
        $t = Get-MsTask -Id $Id -CatalogRoot $script:CatalogRoot
        $answers = New-SampleAnswers $t.Definition
        $actual = New-MsScript -Task $t -Answers $answers -Context $script:Context -Date $script:Date
        $expectedPath = Join-Path (Join-Path $script:Golden 'auto') "$Id.ps1"
        if ($env:MS_SCRIPTER_UPDATE_GOLDEN -eq '1') { Set-Content -Path $expectedPath -Value $actual -NoNewline -Encoding utf8 }
        Test-Path $expectedPath | Should -BeTrue -Because "run with MS_SCRIPTER_UPDATE_GOLDEN=1 once to create it, then review tests/golden/auto/$Id.ps1"
        $actual | Should -Be ((Get-Content -Path $expectedPath -Raw) -replace "`r`n", "`n")
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($actual, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty -Because 'generated one-liners must parse'
        $actual | Should -Not -Match '\{\{' -Because 'no unexpanded tokens'
        $actual | Should -Not -Match 'sample-secret|hunter' -Because 'no secrets'
    }
}
Describe 'Every build path renders as one-liners' {
    It '<Id>' -ForEach $AllPaths {
        $path = Get-MsTask -Id $Id -CatalogRoot $script:CatalogRoot
        $tasks = @(foreach ($tid in $path.Definition.Tasks) { Get-MsTask -Id $tid -CatalogRoot $script:CatalogRoot })
        $share = if ($path.Definition.ContainsKey('Share')) { $path.Definition.Share } else { @{} }
        $answers = @{}
        foreach ($t in $tasks) { foreach ($kv in (New-SampleAnswers $t.Definition).GetEnumerator()) { if (-not $answers.ContainsKey($kv.Key)) { $answers[$kv.Key] = $kv.Value } } }
        foreach ($target in $share.Keys) { $answers.Remove($target) }     # shared fields come from the source task's answer
        $actual = New-MsScript -Task $tasks -Answers $answers -Context $script:Context -Share $share -Date $script:Date
        $expectedPath = Join-Path (Join-Path $script:Golden 'auto') "$Id.ps1"
        if ($env:MS_SCRIPTER_UPDATE_GOLDEN -eq '1') { Set-Content -Path $expectedPath -Value $actual -NoNewline -Encoding utf8 }
        Test-Path $expectedPath | Should -BeTrue
        $actual | Should -Be ((Get-Content -Path $expectedPath -Raw) -replace "`r`n", "`n")
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($actual, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
}
Describe 'New-MsScript' {
    It 'matches the golden file for <Name>' -ForEach $Cases {
        $expectedPath = Join-Path $script:Golden "$Name.ps1"
        $actual = Invoke-Case $_
        if ($env:MS_SCRIPTER_UPDATE_GOLDEN -eq '1') { Set-Content -Path $expectedPath -Value $actual -NoNewline -Encoding utf8 }
        Test-Path $expectedPath | Should -BeTrue -Because "run with MS_SCRIPTER_UPDATE_GOLDEN=1 once to create tests/golden/$Name.ps1, then review it"
        $expected = (Get-Content -Path $expectedPath -Raw) -replace "`r`n", "`n"
        $actual | Should -Be $expected
    }
    It 'produces text that parses as PowerShell for <Name>' -ForEach $Cases {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput((Invoke-Case $_), [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
    It 'refuses to generate when a required answer is missing' {
        $t = Get-MsTask -Id azure.create.resource-group -CatalogRoot $script:CatalogRoot
        { New-MsScript -Task $t -Answers @{ Location = 'eastus2' } } | Should -Throw '*required*'
    }
    It 'refuses to generate when a pattern does not match' {
        $t = Get-MsTask -Id azure.create.resource-group -CatalogRoot $script:CatalogRoot
        { New-MsScript -Task $t -Answers @{ Name = 'bad name!'; Location = 'eastus2' } } | Should -Throw '*does not match*'
    }
    It 'never contains a secret value' {
        $t = @{
            Id = 'x.y.z'; Title = 'T'; Summary = 'S'; Status = 'Untested'
            Requires = @{ Auth = 'None' }
            Fields = @(@{ Name = 'Pw'; Label = 'Local admin'; Type = 'Secret' })
            Steps = @(@{ Title = 'a'; What = 'b'; Why = 'c'; Cmdlet = 'New-Thing'; Parameters = @{ Credential = '{{Pw}}' } })
        }
        $out = New-MsScript -Task $t -Answers @{ Pw = 'hunter2' } -Date $script:Date
        $out | Should -Not -Match 'hunter2'
        $out | Should -Match 'Get-Credential'
    }
    It 'defaults to one-liners with no comments and no splat' {
        $t = Get-MsTask -Id azure.create.resource-group -CatalogRoot $script:CatalogRoot
        $out = New-MsScript -Task $t -Answers @{ Name = 'rg-lab'; Location = 'eastus2' } -Date $script:Date
        $out.Trim() | Should -Be "New-AzResourceGroup -Name 'rg-lab' -Location 'eastus2'"
    }
    It 'one-liners have no variables: helper calls are nested inline and teaching steps are dropped' {
        $t = Get-MsTask -Id azure.network.new-vnet -CatalogRoot $script:CatalogRoot
        $out = New-MsScript -Task $t -Answers @{ ResourceGroupName = 'rg'; Location = 'eastus2'; VNetName = 'vnet'; AddressPrefix = '10.0.0.0/16'; SubnetName = 's'; SubnetPrefix = '10.0.1.0/24' } -Date $script:Date
        $out.Trim() | Should -Be "New-AzVirtualNetwork -Name 'vnet' -ResourceGroupName 'rg' -Location 'eastus2' -AddressPrefix '10.0.0.0/16' -Subnet (New-AzVirtualNetworkSubnetConfig -Name 's' -AddressPrefix '10.0.1.0/24')"
        $out | Should -Not -Match '\$'
    }
    It 'one-liners assign a variable only when Verify or Rollback is included and uses it' {
        $t = Get-MsTask -Id m365.groups.new-security-group -CatalogRoot $script:CatalogRoot
        $a = @{ DisplayName = 'G'; MailNickname = 'g' }
        (New-MsScript -Task $t -Answers $a -Date $script:Date)               | Should -Not -Match '\$group'
        (New-MsScript -Task $t -Answers $a -Date $script:Date -WithRollback) | Should -Match '(?m)^\$group = New-MgGroup'
    }
    It 'drops a step whose When field is empty' {
        $t = @{
            Id = 'x.y.z'; Title = 'T'; Summary = 'S'; Status = 'Untested'
            Requires = @{ Auth = 'None' }
            Fields = @(@{ Name = 'Extra'; Label = 'Extra'; Type = 'Bool' })
            Steps = @(
                @{ Title = 'always'; What = 'b'; Why = 'c'; Raw = @('Write-Output 1') }
                @{ Title = 'maybe';  What = 'b'; Why = 'c'; Raw = @('Write-Output 2'); When = 'Extra' }
            )
        }
        (New-MsScript -Task $t -Answers @{} -Date $script:Date)              | Should -Not -Match 'Write-Output 2'
        (New-MsScript -Task $t -Answers @{ Extra = $true } -Date $script:Date) | Should -Match 'Write-Output 2'
    }
}
