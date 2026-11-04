# Read-only Azure mode. These tests use the real, unmodified azure/readonly source
# against fake Az modules on disk (helpers/FakeAz.ps1). The fakes fail on any write.
BeforeDiscovery {
    $script:RealAz = @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network', 'Az.DesktopVirtualization' |
        Where-Object { -not (Get-Module -ListAvailable -Name $_) }).Count -eq 0
}
BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/FakeAz.ps1')
    $script:ReadOnlyRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'readonly'
    $script:Manifest = Join-Path $script:ReadOnlyRoot 'AzureReadOnly' 'AzureReadOnly.psd1'
    $script:Console = Join-Path $script:ReadOnlyRoot 'Start-AzureReadOnly.ps1'
    $script:Tenant = 'aaaaaaaa-0000-0000-0000-000000000001'
    $script:Lab = 'bbbbbbbb-0000-0000-0000-000000000001'
    $script:Prod = 'bbbbbbbb-0000-0000-0000-000000000002'
    $script:SavedModulePath = $env:PSModulePath
    $env:PSModulePath = (New-FakeAzModule -Path (Join-Path $TestDrive 'fake-az')) + [IO.Path]::PathSeparator + $env:PSModulePath
    function Reset-FakeAz {
        foreach ($m in 'Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network', 'Az.DesktopVirtualization', 'AzureReadOnly') { Remove-Module $m -Force -ErrorAction SilentlyContinue }
        $global:FakeAz = New-FakeAzState
        Import-Module $script:Manifest -Force
    }
    function Connect-Lab { $null = Connect-AzReadOnly -TenantId $script:Tenant -SubscriptionId $script:Lab }
    function Get-FakeCall { param([string]$Name) @($global:FakeAz.Calls | Where-Object Name -eq $Name) }
}
AfterAll {
    $env:PSModulePath = $script:SavedModulePath
    foreach ($m in 'Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network', 'Az.DesktopVirtualization', 'AzureReadOnly') { Remove-Module $m -Force -ErrorAction SilentlyContinue }
    Remove-Variable FakeAz -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Azure read-only command allowlist' {
    BeforeAll { Reset-FakeAz; $script:Policy = @(Get-AzReadCommandPolicy) }

    It 'contains exactly the reviewed commands' {
        $script:Policy.Name | Should -Be @(
            'Connect-AzAccount', 'Disable-AzContextAutosave', 'Get-AzContext', 'Get-AzNetworkSecurityGroup', 'Get-AzResourceGroup',
            'Get-AzSubscription', 'Get-AzVirtualNetwork', 'Get-AzVM', 'Get-AzWvdApplicationGroup', 'Get-AzWvdHostPool',
            'Get-AzWvdScalingPlan', 'Get-AzWvdSessionHost', 'Get-AzWvdUserSession', 'Get-AzWvdWorkspace', 'Invoke-AzRestMethod', 'Set-AzContext')
    }
    It 'admits only Get commands outside the pinned session and permission-check commands' {
        foreach ($p in $script:Policy | Where-Object Name -notin 'Connect-AzAccount', 'Disable-AzContextAutosave', 'Set-AzContext', 'Invoke-AzRestMethod') {
            $p.Name | Should -BeLike 'Get-*'
        }
        foreach ($name in 'Connect-AzAccount', 'Disable-AzContextAutosave', 'Set-AzContext') {
            ($script:Policy | Where-Object Name -eq $name).Pinned.Scope | Should -BeExactly 'Process'
        }
        $rest = $script:Policy | Where-Object Name -eq 'Invoke-AzRestMethod'
        $rest.Pinned.Method | Should -BeExactly 'GET'
        $rest.Parameters | Should -Be @('Path')
        $rest.Path | Should -BeExactly '/subscriptions/{subscription}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01'
    }
    It 'excludes commands and parameters that return secrets or run code' {
        foreach ($name in 'Get-AzAccessToken', 'Get-AzStorageAccountKey', 'Get-AzKeyVaultSecret', 'Get-AzKeyVaultKey', 'Get-AzWvdRegistrationInfo',
            'Get-AzWebAppPublishingProfile', 'Invoke-AzVMRunCommand', 'Get-AzVMRunCommand', 'Get-AzStorageContext') {
            $script:Policy.Name | Should -Not -Contain $name
        }
        ($script:Policy | Where-Object Name -eq 'Get-AzVM').Parameters | Should -Not -Contain 'UserData'
        foreach ($p in $script:Policy) {
            @($p.Parameters | Where-Object { $_ -in 'DefaultProfile', 'Scope', 'Method', 'Payload', 'Uri', 'AsJob', 'HttpPipelinePrepend', 'HttpPipelineAppend', 'Proxy' }) | Should -BeNullOrEmpty -Because $p.Name
        }
    }
}

Describe 'Azure read-only source boundary' {
    BeforeAll {
        $script:Files = @(Get-ChildItem $script:ReadOnlyRoot -Recurse -File | Where-Object Extension -in '.ps1', '.psm1')
        $script:PolicyNames = @(& { Reset-FakeAz; Get-AzReadCommandPolicy } | ForEach-Object Name)
        $script:Exports = @((Import-PowerShellDataFile $script:Manifest).FunctionsToExport)
        $script:Builtins = @('Set-StrictMode', 'Get-Command', 'Get-Module', 'Select-Object', 'Where-Object', 'ForEach-Object', 'Sort-Object',
            'Measure-Object', 'ConvertFrom-Json', 'Export-ModuleMember', 'Import-Module', 'Join-Path', 'Write-Host', 'Read-Host',
            'Format-Table', 'Out-String')
        function Get-Ast { param($File) [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$null, [ref]$null) }
    }
    It 'parses every file' {
        $script:Files.Count | Should -Be 2
        foreach ($f in $script:Files) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty -Because $f.Name
        }
    }
    It 'calls only built-ins on the reviewed list, its own functions, and the module exports' {
        foreach ($f in $script:Files) {
            $ast = Get-Ast $f
            $own = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
            $allowed = $script:Builtins + $own + $(if ($f.Extension -eq '.ps1') { $script:Exports } else { @() })
            foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $call.InvocationOperator | Should -Not -Be 'Dot' -Because "$($f.Name): $($call.Extent.Text)"
                $name = $call.GetCommandName()
                if ($null -eq $name) { continue }
                $allowed | Should -Contain $name -Because "$($f.Name): $($call.Extent.Text)"
                $script:PolicyNames | Should -Not -Contain $name -Because 'Azure calls go through Invoke-AzReadCommand'
            }
        }
    }
    It 'has exactly one dynamic invocation: the gateway call to the resolved allowlisted command' {
        $dynamic = foreach ($f in $script:Files) {
            (Get-Ast $f).FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $null -eq $n.GetCommandName() }, $true)
        }
        @($dynamic).Count | Should -Be 1
        $dynamic[0].Extent.Text | Should -BeExactly '& $command @arguments'
        $owner = $dynamic[0].Parent
        while ($owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
        $owner.Name | Should -BeExactly 'Invoke-AzReadCommand'
    }
    It 'names a literal allowlisted command at every gateway call, and uses every allowlist entry' {
        $used = foreach ($f in $script:Files) {
            foreach ($call in (Get-Ast $f).FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-AzReadCommand' }, $true)) {
                $first = $call.CommandElements[1]
                $first | Should -BeOfType ([System.Management.Automation.Language.StringConstantExpressionAst]) -Because $call.Extent.Text
                $script:PolicyNames | Should -Contain $first.Value
                $first.Value
            }
        }
        @($used | Sort-Object -Unique) | Should -Be @($script:PolicyNames | Sort-Object)
    }
    It 'loads only its own manifest and nothing that creates or runs code at runtime' {
        foreach ($f in $script:Files) {
            $ast = Get-Ast $f
            $imports = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true))
            if ($f.Extension -eq '.psm1') { $imports | Should -BeNullOrEmpty }
            else {
                $imports.Count | Should -Be 1
                $imports[0].Extent.Text | Should -BeExactly "Import-Module (Join-Path `$PSScriptRoot 'AzureReadOnly' 'AzureReadOnly.psd1') -Force"
            }
            @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -in 'ExecutionContext', 'PSDefaultParameterValues' }, $true)) | Should -BeNullOrEmpty
            @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -and $n.TypeName.FullName -match 'scriptblock|powershell|runspace|activator|reflection|assembly|process' }, $true)) | Should -BeNullOrEmpty
            @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and "$($n.Member)" -match '^(Invoke|InvokeReturnAsIs|InvokeScript|NewScriptBlock|AddScript|AddCommand|Create|GetNewClosure)$' }, $true)) | Should -BeNullOrEmpty
        }
        Get-ChildItem $script:ReadOnlyRoot -Recurse -File | Select-String -Pattern 'scripts[\\/]powershell|AzHelpers|AvdHelpers|AvdBuild' | Should -BeNullOrEmpty
    }
    It 'never assigns a local variable spelled like one of its function''s parameters' {
        # PowerShell variable names ignore case, so $subscriptionId replaces -SubscriptionId.
        foreach ($f in $script:Files) {
            $ast = Get-Ast $f
            $scopes = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Body) + $ast
            foreach ($scope in $scopes) {
                $params = @($scope.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                if (-not $params.Count) { continue }
                $assigned = $scope.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $false) |
                    ForEach-Object { $_.Left } | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] } |
                    ForEach-Object { $_.VariablePath.UserPath }
                foreach ($name in $assigned) {
                    # The console's tenant prompt fills its own empty -TenantId on purpose.
                    if ($f.Extension -eq '.ps1' -and $scope -eq $ast -and $name -eq 'TenantId') { continue }
                    $params | Should -Not -Contain $name -Because "$($f.Name) assigns `$$name"
                }
            }
        }
    }
    It 'sets its own Stop preference first in every exported function and in the gateway' {
        $ast = Get-Ast (Get-Item (Join-Path $script:ReadOnlyRoot 'AzureReadOnly' 'AzureReadOnly.psm1'))
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object { $_.Name -in $script:Exports + 'Invoke-AzReadCommand' + 'Assert-AzReadOnlyContext' -and $_.Name -notin 'Get-AzReadCommandPolicy', 'Get-AzReadOnlyMissingModule', 'Get-AzReadOnlySession' }) {
            $fn.Body.EndBlock.Statements[0].Extent.Text | Should -BeExactly "`$ErrorActionPreference = 'Stop'" -Because $fn.Name
        }
    }
}

Describe 'Azure read-only gateway' {
    BeforeEach { Reset-FakeAz }

    It 'refuses <Name> before resolving or running anything' -ForEach @(
        @{ Name = 'Remove-AzVM' }, @{ Name = 'Invoke-AzVMRunCommand' }, @{ Name = 'Get-AzAccessToken' }, @{ Name = 'Get-AzWvdRegistrationInfo' },
        @{ Name = 'Update-AzWvdSessionHost' }, @{ Name = 'Clear-AzContext' }, @{ Name = 'Get-AzV*' }, @{ Name = 'Get-AzVM ' }, @{ Name = 'Microsoft.PowerShell.Utility\Invoke-Expression' }
    ) {
        $module = Get-Module AzureReadOnly
        { & $module { param($n) Invoke-AzReadCommand $n } $Name } | Should -Throw "*Azure read-only mode refuses '$Name'*"
        { & $module { param($n) Invoke-AzReadCommand $n -ErrorAction Ignore } $Name } | Should -Throw '*not an allowlisted read command*'
        $global:FakeAz.Calls | Should -BeNullOrEmpty
        $global:FakeAz.Writes | Should -BeNullOrEmpty
        Get-Module Az.Compute, Az.Accounts | Should -BeNullOrEmpty
    }
    It 'refuses unlisted, abbreviated, alias and common parameters: <Name> -<Key>' -ForEach @(
        @{ Name = 'Get-AzVM'; Key = 'UserData' }, @{ Name = 'Get-AzVM'; Key = 'Stat' }, @{ Name = 'Get-AzVM'; Key = 'Name' },
        @{ Name = 'Get-AzVM'; Key = 'DefaultProfile' }, @{ Name = 'Get-AzVM'; Key = 'ErrorAction' }, @{ Name = 'Connect-AzAccount'; Key = 'Scope' },
        @{ Name = 'Connect-AzAccount'; Key = 'AccessToken' }, @{ Name = 'Disable-AzContextAutosave'; Key = 'Scope' },
        @{ Name = 'Invoke-AzRestMethod'; Key = 'Method' }, @{ Name = 'Invoke-AzRestMethod'; Key = 'Payload' }, @{ Name = 'Invoke-AzRestMethod'; Key = 'Uri' },
        @{ Name = 'Get-AzWvdHostPool'; Key = 'HttpPipelinePrepend' }
    ) {
        $module = Get-Module AzureReadOnly
        { & $module { param($n, $k) Invoke-AzReadCommand $n @{ $k = 'fixture' } -ErrorAction SilentlyContinue } $Name $Key } |
            Should -Throw "*refuses parameter -$Key for $Name*"
        $global:FakeAz.Calls | Should -BeNullOrEmpty
    }
    It 'allows only GET of the selected subscription''s own permissions' {
        Connect-Lab
        $global:FakeAz.Calls.Clear()
        $module = Get-Module AzureReadOnly
        $good = "/subscriptions/$($script:Lab)/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
        foreach ($path in @("/subscriptions/$($script:Prod)/providers/Microsoft.Authorization/permissions?api-version=2022-04-01",
            "/subscriptions/$($script:Lab)/resourceGroups/rg-avd?api-version=2022-04-01", "$good&`$filter=x", $good.ToUpperInvariant(), '', "https://management.azure.com$good")) {
            { & $module { param($p) Invoke-AzReadCommand 'Invoke-AzRestMethod' @{ Path = $p } -ErrorAction Ignore } $path } | Should -Throw '*only the selected subscription*' -Because $path
        }
        Get-FakeCall 'Invoke-AzRestMethod' | Should -BeNullOrEmpty
        $null = & $module { param($p) Invoke-AzReadCommand 'Invoke-AzRestMethod' @{ Path = $p } } $good
        $call = Get-FakeCall 'Invoke-AzRestMethod'
        $call.Count | Should -Be 1
        $call[0].Parameters.Method | Should -BeExactly 'GET'
        $call[0].Parameters.WhatIf | Should -BeFalse
        $call[0].Parameters.Keys | Should -Not -Contain 'Payload'
    }
    It 'refuses the permission check before sign-in' {
        $module = Get-Module AzureReadOnly
        { & $module { Invoke-AzReadCommand 'Invoke-AzRestMethod' @{ Path = '/subscriptions/{subscription}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01' } } } | Should -Throw '*only the selected subscription*'
    }
    It 'uses the command from its Az module, not a same-named global function' {
        function global:Get-AzResourceGroup { $global:FakeAz.Writes.Add('global shadow') }
        try {
            Connect-Lab
            @(Get-AzReadOnlyResourceGroup).Count | Should -Be 2
            $global:FakeAz.Writes | Should -BeNullOrEmpty
        } finally { Remove-Item function:global:Get-AzResourceGroup }
    }
}

Describe 'Azure read-only sign-in' {
    BeforeEach { Reset-FakeAz }

    It 'keeps the sign-in in this process, then signs in to the requested tenant only' {
        $session = Connect-AzReadOnly -TenantId $script:Tenant -SubscriptionId $script:Lab -UseDeviceAuthentication
        $session.SubscriptionId | Should -Be $script:Lab
        $session.AccountId | Should -Be 'reader@fixture.example'
        $names = @($global:FakeAz.Calls.Name)
        $names[0..2] | Should -Be @('Disable-AzContextAutosave', 'Connect-AzAccount', 'Get-AzContext')
        $autosave = (Get-FakeCall 'Disable-AzContextAutosave')[0].Parameters
        $autosave.Scope | Should -BeExactly 'Process'
        $autosave.WhatIf | Should -BeFalse
        $autosave.Confirm | Should -BeFalse
        $connect = (Get-FakeCall 'Connect-AzAccount')[0].Parameters
        $connect.Tenant | Should -Be $script:Tenant
        $connect.Subscription | Should -Be $script:Lab
        $connect.Scope | Should -BeExactly 'Process'
        $connect.UseDeviceAuthentication | Should -BeTrue
        $global:FakeAz.Writes | Should -BeNullOrEmpty
    }
    It 'refuses to sign in when autosave cannot be limited to this process' {
        $global:FakeAz.AutosaveMode = 'CurrentUser'
        { Connect-AzReadOnly -TenantId $script:Tenant -ErrorAction SilentlyContinue } | Should -Throw '*could not keep the sign-in in this process only*'
        Get-FakeCall 'Connect-AzAccount' | Should -BeNullOrEmpty
        Get-AzReadOnlySession | Should -BeNullOrEmpty
    }
    It 'refuses a sign-in that lands in another tenant' {
        $global:FakeAz.SignInTenant = 'aaaaaaaa-0000-0000-0000-000000000002'
        { Connect-AzReadOnly -TenantId $script:Tenant } | Should -Throw '*not the account that just signed in to tenant*'
        Get-AzReadOnlySession | Should -BeNullOrEmpty
    }
    It 'refuses when the active context is not the one that just signed in' {
        $global:FakeAz.ContextOverride = New-FakeAzContext -Tenant $script:Tenant -Subscription $global:FakeAz.Subscriptions[0]
        $global:FakeAz.ContextOverride.Account.Id = 'other@fixture.example'
        { Connect-AzReadOnly -TenantId $script:Tenant } | Should -Throw '*not the account that just signed in*'
        Get-AzReadOnlySession | Should -BeNullOrEmpty
    }
    It 'refuses a subscription other than the one requested' {
        $global:FakeAz.SignInSubscription = $global:FakeAz.Subscriptions[1]
        { Connect-AzReadOnly -TenantId $script:Tenant -SubscriptionId $script:Lab } | Should -Throw "*selected subscription '$($script:Prod)'*"
        Get-AzReadOnlySession | Should -BeNullOrEmpty
    }
    It 'refuses non-interactive account types' {
        $global:FakeAz.AccountType = 'ServicePrincipal'
        { Connect-AzReadOnly -TenantId $script:Tenant } | Should -Throw '*interactive user sign-in only*'
    }
    It 'rejects a tenant or subscription that is not a GUID' {
        { Connect-AzReadOnly -TenantId 'contoso.example' } | Should -Throw
        { Connect-AzReadOnly -TenantId $script:Tenant -SubscriptionId 'Lab' } | Should -Throw
        $global:FakeAz.Calls | Should -BeNullOrEmpty
    }
    It 'adopts the default subscription only when it belongs to the tenant, and switches within the tenant' {
        $session = Connect-AzReadOnly -TenantId $script:Tenant
        $session.SubscriptionId | Should -Be $script:Lab
        @(Get-AzReadOnlySubscription).Id | Should -Be @($script:Lab, $script:Prod)
        (Select-AzReadOnlySubscription -SubscriptionId $script:Prod).SubscriptionName | Should -Be 'Production'
        $set = (Get-FakeCall 'Set-AzContext')[0].Parameters
        $set.Scope | Should -BeExactly 'Process'
        $set.Tenant | Should -Be $script:Tenant
        { Select-AzReadOnlySubscription -SubscriptionId 'bbbbbbbb-0000-0000-0000-000000000003' } | Should -Throw '*not readable by this account in tenant*'
        (Get-AzReadOnlySession).SubscriptionId | Should -Be $script:Prod
    }
    It 'refuses <Name> when the Azure context changes after sign-in' -ForEach @(
        @{ Name = 'Get-AzReadOnlyVm'; Arguments = @{} }, @{ Name = 'Get-AzReadOnlyResourceGroup'; Arguments = @{} }
        @{ Name = 'Get-AzReadOnlyAvdEnvironment'; Arguments = @{} }, @{ Name = 'Get-AzReadOnlyAvdHealth'; Arguments = @{} }
        @{ Name = 'Get-AzReadOnlyNetwork'; Arguments = @{} }, @{ Name = 'Get-AzReadOnlyAccess'; Arguments = @{} }
        @{ Name = 'Get-AzReadOnlyHostPool'; Arguments = @{ ResourceGroupName = 'rg-avd'; HostPoolName = 'hp-lab' } }
        @{ Name = 'Get-AzReadOnlyUserSession'; Arguments = @{ ResourceGroupName = 'rg-avd'; HostPoolName = 'hp-lab' } }
    ) {
        Connect-Lab
        $global:FakeAz.ContextOverride = New-FakeAzContext -Tenant $script:Tenant -Subscription $global:FakeAz.Subscriptions[1]
        $global:FakeAz.Calls.Clear()
        { & $Name @Arguments -ErrorAction Ignore } | Should -Throw '*Azure context changed after sign-in*'
        @($global:FakeAz.Calls.Name | Sort-Object -Unique) | Should -Be @('Get-AzContext')
    }
    It 'refuses reports before sign-in' {
        { Get-AzReadOnlyVm } | Should -Throw '*sign in first*'
        $global:FakeAz.Calls | Should -BeNullOrEmpty
    }
}

Describe 'Azure read-only reports' {
    BeforeEach { Reset-FakeAz; Connect-Lab; $global:FakeAz.Calls.Clear() }
    AfterEach {
        $global:FakeAz.Writes | Should -BeNullOrEmpty
        foreach ($call in $global:FakeAz.Calls | Where-Object Name -like 'Get-AzWvd*') { $call.Parameters.SubscriptionId | Should -Be $script:Lab }
    }

    It 'lists resource groups and VMs with power state, size and OS' {
        @(Get-AzReadOnlyResourceGroup).Name | Should -Be @('rg-avd', 'rg-avd-hosts')
        $vms = @(Get-AzReadOnlyVm)
        $vms.Name | Should -Be @('avd-0', 'avd-1', 'srv-01')
        ($vms | Where-Object Name -eq 'avd-1').PowerState | Should -Be 'deallocated'
        ($vms | Where-Object Name -eq 'srv-01').OsType | Should -Be 'Linux'
        (Get-FakeCall 'Get-AzVM')[0].Parameters.Status | Should -BeTrue
        @(Get-AzReadOnlyVm -ResourceGroupName rg-servers).Name | Should -Be @('srv-01')
    }
    It 'links host pools to app groups, workspaces and scaling plans' {
        $rows = @(Get-AzReadOnlyAvdEnvironment)
        $rows.HostPool | Should -Be @('hp-empty', 'hp-lab')
        $lab = $rows | Where-Object HostPool -eq 'hp-lab'
        $lab.ResourceGroupName | Should -Be 'rg-avd'
        $lab.AppGroups | Should -Be 'ag-lab-desktop (Desktop), ag-lab-apps (RemoteApp)'
        $lab.Workspaces | Should -Be 'ws-lab'
        $lab.ScalingPlans | Should -Be 'sp-lab'
    }
    It 'joins session hosts to their VMs and reports failed health checks' {
        $d = Get-AzReadOnlyHostPool -ResourceGroupName rg-avd -HostPoolName hp-lab
        $d.Counts.Total | Should -Be 3
        $d.Counts.Sessions | Should -Be 2
        $d.Counts.Running | Should -Be 1
        $d.Counts.Drained | Should -Be 1
        ($d.Hosts | Where-Object Name -eq 'avd-0.corp.example').PowerState | Should -Be 'running'
        ($d.Hosts | Where-Object Name -eq 'avd-1.corp.example').FailedChecks | Should -Be 'DomainJoinedCheck, FSLogixHealthCheck'
        ($d.Hosts | Where-Object Name -eq 'avd-2.corp.example').PowerState | Should -Be 'not found'
        $d.ScalingPlans[0].Schedules | Should -Be 'weekdays (Mon Tue): up 07:00, peak 09:00, down 17:30, off 20:00'
        @(Get-FakeCall 'Get-AzVM').Count | Should -Be 1
        { Get-AzReadOnlyHostPool -ResourceGroupName rg-other -HostPoolName hp-lab } | Should -Throw '*was not found in resource group rg-other*'
    }
    It 'lists user sessions by host' {
        $s = @(Get-AzReadOnlyUserSession -ResourceGroupName rg-avd -HostPoolName hp-lab)
        $s.Count | Should -Be 1
        $s[0].SessionHost | Should -Be 'avd-0.corp.example'
        $s[0].User | Should -Be 'user1@fixture.example'
        $s[0].State | Should -Be 'Active'
    }
    It 'finds the usual AVD problems and keeps going when one pool cannot be read' {
        $findings = @(Get-AzReadOnlyAvdHealth)
        $text = @($findings | ForEach-Object { "$($_.Severity)|$($_.HostPool)|$($_.SessionHost)|$($_.Finding)" })
        $text | Should -Contain 'Problem|hp-lab|avd-1.corp.example|Status is Unavailable.'
        $text | Should -Contain 'Problem|hp-lab|avd-1.corp.example|Failed health checks: DomainJoinedCheck, FSLogixHealthCheck.'
        $text | Should -Contain 'Problem|hp-lab|avd-1.corp.example|The last agent update failed.'
        $text | Should -Contain 'Warning|hp-lab|avd-1.corp.example|Drain mode is on: no new sessions.'
        $text | Should -Contain 'Problem|hp-lab|avd-2.corp.example|Its VM was not found; the session host may be orphaned.'
        $text | Should -Contain 'Warning|hp-lab||Application group ag-lab-apps is not in any workspace, so users do not see it.'
        $text | Should -Contain 'Warning|hp-empty||No session hosts.'
        $text | Should -Contain 'Problem|hp-empty||No application group: users have nothing to open.'
        @($text | Where-Object { $_ -like '*avd-0*' }) | Should -BeNullOrEmpty
        $global:FakeAz.SessionHostReadFailures = @('hp-lab')
        $global:FakeAz.VmReadFailures = @('rg-avd-hosts')
        $text = @(Get-AzReadOnlyAvdHealth | ForEach-Object { "$($_.Severity)|$($_.HostPool)|$($_.Finding)" })
        $text | Should -Contain 'Warning|hp-lab|Could not read session hosts: AuthorizationFailed: cannot read hp-lab'
        $text | Should -Contain 'Problem|hp-empty|No application group: users have nothing to open.'
    }
    It 'does not report a pool as unreachable when its VM power states could not be read' {
        $global:FakeAz.HostPools[0].StartVMOnConnect = $false
        $global:FakeAz.VmReadFailures = @('rg-avd-hosts')
        $text = @(Get-AzReadOnlyAvdHealth | Where-Object HostPool -eq 'hp-lab' | ForEach-Object Finding)
        $text | Should -Contain 'Could not read VMs in resource group rg-avd-hosts; power states are unknown.'
        $text | Should -Not -Contain 'No host is running and Start VM On Connect is off: users cannot connect until a host starts.'
        $global:FakeAz.VmReadFailures = @()
        $global:FakeAz.Vms[0].PowerState = 'VM deallocated'
        @(Get-AzReadOnlyAvdHealth | Where-Object HostPool -eq 'hp-lab' | ForEach-Object Finding) | Should -Contain 'No host is running and Start VM On Connect is off: users cannot connect until a host starts.'
    }
    It 'lists networks and flags inbound rules open to any internet source' {
        $n = Get-AzReadOnlyNetwork
        $n.VirtualNetworks[0].AddressSpace | Should -Be '10.10.0.0/16'
        $n.VirtualNetworks[0].DnsServers | Should -Be '10.10.1.4'
        ($n.Subnets | Where-Object Name -eq 'snet-avd').Nsg | Should -Be 'nsg-avd'
        ($n.Subnets | Where-Object Name -eq 'snet-servers').NatGateway | Should -Be 'yes'
        $n.SecurityGroups[0].OpenToInternet | Should -Be 'allow-rdp-internet (Tcp 3389)'
    }
    It 'reports whether the account could change resources: <Case>' -ForEach @(
        @{ Case = 'Reader'; Json = '{"value":[{"actions":["*/read"],"notActions":[]}]}'; CanChange = $false; Example = $null }
        @{ Case = 'Contributor'; Json = '{"value":[{"actions":["*"],"notActions":["Microsoft.Authorization/*/Write","Microsoft.Authorization/*/Delete"]}]}'; CanChange = $true; Example = 'Microsoft.Compute/virtualMachines/write' }
        @{ Case = 'Owner'; Json = '{"value":[{"actions":["*"],"notActions":[]}]}'; CanChange = $true; Example = 'Microsoft.Authorization/roleAssignments/write' }
        @{ Case = 'VM operator'; Json = '{"value":[{"actions":["*/read"],"notActions":[]},{"actions":["Microsoft.Compute/virtualMachines/deallocate/action"],"notActions":[]}]}'; CanChange = $true; Example = 'Microsoft.Compute/virtualMachines/deallocate/action' }
    ) {
        $global:FakeAz.Permissions = $Json
        $a = Get-AzReadOnlyAccess
        $a.Checked | Should -BeTrue
        $a.CanChange | Should -Be $CanChange
        if ($Example) { $a.Examples | Should -Contain $Example }
        if ($Case -eq 'Contributor') { $a.Examples | Should -Not -Contain 'Microsoft.Authorization/roleAssignments/write' }
    }
    It 'reports an unchecked access level instead of guessing' {
        $global:FakeAz.PermissionStatus = 403
        $a = Get-AzReadOnlyAccess
        $a.Checked | Should -BeFalse
        $a.CanChange | Should -BeNullOrEmpty
        $a.Note | Should -Be 'The permission check returned HTTP 403.'
    }
    It 'never returns secrets carried by raw Azure objects' {
        $out = @(
            Get-AzReadOnlyResourceGroup; Get-AzReadOnlyVm; Get-AzReadOnlyAvdEnvironment; Get-AzReadOnlyAvdHealth; Get-AzReadOnlyNetwork; Get-AzReadOnlyAccess
            Get-AzReadOnlyHostPool -ResourceGroupName rg-avd -HostPoolName hp-lab; Get-AzReadOnlyUserSession -ResourceGroupName rg-avd -HostPoolName hp-lab
        ) | ConvertTo-Json -Depth 8
        $out | Should -Not -Match 'FIXTURE-SECRET'
    }
}

Describe 'Azure read-only console' {
    BeforeEach {
        Reset-FakeAz
        # Mock bodies run outside this file's script scope, so the queues are global.
        $script:Answers = $global:ReadOnlyTestAnswers = [System.Collections.Generic.Queue[string]]::new()
        $script:Screen = $global:ReadOnlyTestScreen = [System.Collections.Generic.List[string]]::new()
        Mock Read-Host { if ($global:ReadOnlyTestAnswers.Count -eq 0) { throw 'Console asked for more input than the test supplied.' }; $global:ReadOnlyTestAnswers.Dequeue() }
        Mock Write-Host { $global:ReadOnlyTestScreen.Add("$Object") }
    }
    AfterEach { $global:FakeAz.Writes | Should -BeNullOrEmpty }
    AfterAll { Remove-Variable ReadOnlyTestAnswers, ReadOnlyTestScreen -Scope Global -ErrorAction SilentlyContinue }

    It 'signs in, runs every option, switches subscription and quits' {
        # Menu answers, with the pickers' choices: Lab is the first subscription by name,
        # hp-lab the second host pool by name.
        foreach ($a in $script:Tenant, '1', '2', '1', '3', '4', '5', '6', '2', '7', '2', '8', '9', '10', 'bogus', 'q') { $script:Answers.Enqueue($a) }
        $global:FakeAz.Subscriptions = @($global:FakeAz.Subscriptions[1], $global:FakeAz.Subscriptions[0], $global:FakeAz.Subscriptions[2])
        & $script:Console
        $script:Answers.Count | Should -Be 0
        $text = $script:Screen -join "`n"
        $text | Should -Match 'SAFE MODE: read-only'
        $text | Should -Match 'Subscription: Production \(bbbbbbbb-0000-0000-0000-000000000002\)'
        $text | Should -Match 'Subscription: Lab \(bbbbbbbb-0000-0000-0000-000000000001\)'
        $text | Should -Match 'Access:       read-only at subscription scope'
        foreach ($heading in 'Subscriptions', 'Resource groups', 'Virtual machines', 'AVD host pools', 'Session hosts', 'Application groups', 'Scaling plans',
            'User sessions in hp-lab', 'AVD health', 'Virtual networks', 'Subnets') {
            $script:Screen | Should -Contain $heading
        }
        $text | Should -Match 'hp-lab in rg-avd \(westus3\): Pooled, BreadthFirst, max 8 sessions per host'
        $text | Should -Match 'Failed health checks: DomainJoinedCheck, FSLogixHealthCheck'
        $text | Should -Match 'allow-rdp-internet \(Tcp 3389\)'
        $text | Should -Match 'user1@fixture.example'
        $text | Should -Match 'Choose 1-10 or Q.'
        $text | Should -Not -Match 'FIXTURE-SECRET'
        (Get-FakeCall 'Connect-AzAccount')[0].Parameters.Keys | Should -Not -Contain 'Subscription'
        (Get-FakeCall 'Set-AzContext').Count | Should -Be 1
        @($global:FakeAz.Calls.Name | Where-Object { $_ -notin (Get-AzReadCommandPolicy).Name }) | Should -BeNullOrEmpty
    }
    It 'asks for a subscription when the sign-in has none selected' {
        $global:FakeAz.SignInWithoutSubscription = $true
        foreach ($a in '2', 'q') { $script:Answers.Enqueue($a) }
        & $script:Console -TenantId $script:Tenant
        $script:Screen | Should -Contain 'Subscription'
        ($script:Screen -join "`n") | Should -Match 'Subscription: Production'
        (Get-FakeCall 'Set-AzContext')[0].Parameters.Subscription | Should -Be $script:Prod
    }
    It 'passes the tenant, subscription and device-code sign-in through and warns about change rights' {
        $global:FakeAz.Permissions = '{"value":[{"actions":["*"],"notActions":[]}]}'
        $script:Answers.Enqueue('q')
        & $script:Console -TenantId $script:Tenant -SubscriptionId $script:Lab -UseDeviceAuthentication
        $connect = (Get-FakeCall 'Connect-AzAccount')[0].Parameters
        $connect.Subscription | Should -Be $script:Lab
        $connect.UseDeviceAuthentication | Should -BeTrue
        ($script:Screen -join "`n") | Should -Match 'this account CAN CHANGE resources here'
    }
    It 'shows an unchecked access level when the permission check fails at startup' {
        $global:FakeAz.Fail = @('Invoke-AzRestMethod')
        $script:Answers.Enqueue('q')
        & $script:Console -TenantId $script:Tenant -SubscriptionId $script:Lab
        $script:Screen | Should -Contain 'Access:       not checked: AuthorizationFailed: fixture Invoke-AzRestMethod'
    }
    It 'prints a failed read in red and returns to the menu' {
        $global:FakeAz.Fail = @('Get-AzResourceGroup')
        foreach ($a in '3', '5', 'q') { $script:Answers.Enqueue($a) }
        $global:FakeAz.HostPools = @()
        & $script:Console -TenantId $script:Tenant -SubscriptionId $script:Lab
        Should -Invoke Write-Host -ParameterFilter { $ForegroundColor -eq 'Red' -and "$Object" -eq '  AuthorizationFailed: fixture Get-AzResourceGroup' }
        $script:Screen | Should -Contain '  No host pools in this subscription.'
    }
    It 'quits on a blank tenant without signing in' {
        foreach ($a in 'not-a-guid', '') { $script:Answers.Enqueue($a) }
        & $script:Console
        $script:Screen | Should -Contain '  Enter the tenant ID GUID from Entra ID > Overview.'
        $global:FakeAz.Calls | Should -BeNullOrEmpty
    }
    It 'reports missing Az modules instead of installing them' {
        Mock Get-AzReadOnlyMissingModule { 'Az.DesktopVirtualization' }
        { & $script:Console -TenantId $script:Tenant } | Should -Throw '*Install-Module Az.DesktopVirtualization -Scope CurrentUser*'
        $global:FakeAz.Calls | Should -BeNullOrEmpty
    }
}

Describe 'Real Az module metadata' -Skip:(-not $script:RealAz) {
    It 'finds every allowlisted command and parameter in the installed Az modules' {
        $probe = Join-Path $TestDrive 'metadata.ps1'
        @'
param($Manifest)
$ErrorActionPreference = 'Stop'
Import-Module $Manifest -Force
$problems = foreach ($p in Get-AzReadCommandPolicy) {
    Import-Module $p.Module -WarningAction SilentlyContinue
    $command = Get-Command -Name $p.Name -Module $p.Module -ErrorAction SilentlyContinue
    if (-not $command) { "$($p.Name) is not in $($p.Module)"; continue }
    foreach ($name in @($p.Parameters) + @($p.Pinned.Keys)) {
        if (-not $command.Parameters.ContainsKey($name)) { "$($p.Name) has no -$name" }
    }
    if ($p.Name -like 'Get-*' -and $command.Parameters.ContainsKey('WhatIf')) { "$($p.Name) supports ShouldProcess" }
}
"$(@($problems).Count) problem(s)"
$problems
'@ | Set-Content $probe
        $executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $output = & $executable -NoLogo -NoProfile -File $probe -Manifest $script:Manifest 2>&1 | Out-String
        $output | Should -Match '^0 problem\(s\)' -Because $output
    }
}
