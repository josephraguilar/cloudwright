BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/LegacyAzure.ps1')
    $script:AzureTestRoot = New-LegacyAzureTestCopy -Destination (Join-Path $TestDrive 'legacy-azure')
    $script:Scripts = Join-Path $script:AzureTestRoot 'scripts/powershell'
    function Get-SafetyArguments {
        param($Path)
        $values = @{}
        foreach ($p in (Get-Command $Path).Parameters.Values) {
            if (-not @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count) { continue }
            $set = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues)
            $values[$p.Name] = if ($p.ParameterType -eq [pscredential]) {
                [pscredential]::new('fixture', (ConvertTo-SecureString 'Fixture-only-password1!' -AsPlainText -Force))
            } elseif ($set.Count) { $set[0] } elseif ($p.ParameterType -eq [int]) { 1 } else { 'fixture' }
        }
        return $values
    }
}
Describe 'Legacy workflow regression checks on an offline test copy' {
    BeforeEach { Mock Import-Module { throw 'An unsafe workflow reached module initialization' } }
    It 'rejects Entra reimage before authentication, drain, or destruction' {
        $path = Join-Path $script:Scripts 'avd/Invoke-AvdHostReimage.ps1'
        $p = Get-SafetyArguments $path
        $p.JoinType = 'EntraId'
        { & $path @p -Confirm:$false } | Should -Throw '*Entra-joined reimage is disabled*'
        Should -Invoke Import-Module -Times 0
    }
    It 'rejects the retired cleanup switch in <Name> before initialization' -ForEach @(
        @{ Name = 'New-AvdEnvironment.ps1' }, @{ Name = 'New-AvdSessionHost.ps1' }, @{ Name = 'Repair-AvdSessionHost.ps1' }
    ) {
        $path = Join-Path $script:Scripts "avd/$Name"
        $p = Get-SafetyArguments $path
        $p.RemoveStaleEntraDevice = $true
        { & $path @p -Confirm:$false } | Should -Throw '*RemoveStaleEntraDevice is disabled*'
        Should -Invoke Import-Module -Times 0
    }
    It 'blocks the legacy Azure console before initialization' {
        { & (Join-Path $script:Scripts 'Start-AvdConsole.ps1') } | Should -Throw '*Azure/AVD administration is disabled*'
        Should -Invoke Import-Module -Times 0
    }
}
