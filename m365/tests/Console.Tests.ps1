#   WHAT   Drives the console's Invoke-ReviewedCommand with a fake task script: it must dry run
#          first, list the changes, run only after the operator types "yes", run only the
#          listed changes, and never let a read-only task change anything.
#   WHY    This is the path every console task takes; the GUI dock follows the same rules.

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Import-Module (Join-Path $script:Repo 'scripts' 'powershell' 'modules' 'M365Helpers' 'M365Helpers.psd1') -Force
    . (Join-Path $script:Repo 'scripts' 'powershell' 'Start-M365Console.ps1')
    $env:M365_TOOLKIT_LOG_PATH = Join-Path $TestDrive 'logs'

    $global:ConsoleCalls = [System.Collections.Generic.List[string]]::new()
    function global:New-FakeThing { [CmdletBinding(SupportsShouldProcess)] param($Name) $global:ConsoleCalls.Add("New:$Name"); [pscustomobject]@{ Id = 'id-1' } }
    New-Module -Name ConsoleDemo -ScriptBlock {
        function Invoke-FakeTask {
            [CmdletBinding(SupportsShouldProcess)]
            param([string]$Name, [switch]$Sneaky)
            $null = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Create thing '$Name'" -Command 'New-FakeThing' -Parameters ([ordered]@{ Name = $Name })
            #   A change that only happens on the real run, never in the dry run.
            if ($Sneaky -and -not $WhatIfPreference) { $null = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action 'Something not shown' -Command 'New-FakeThing' -Parameters ([ordered]@{ Name = 'unplanned' }) }
        }
        Export-ModuleMember -Function Invoke-FakeTask
    } | Import-Module -Force
    $script:Task = Join-Path $TestDrive 'Fake-Task.ps1'
    Set-Content $script:Task @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$Name, [switch]$Sneaky)
Invoke-FakeTask -Name $Name -Sneaky:$Sneaky -WhatIf:$WhatIfPreference
'@
    $script:ReadOnly = Join-Path $TestDrive 'Fake-Read.ps1'
    Set-Content $script:ReadOnly @'
[CmdletBinding()]
param([string]$Name)
Invoke-FakeTask -Name $Name
'@
}
AfterAll {
    Remove-Item Function:\New-FakeThing -ErrorAction SilentlyContinue
    Remove-Module ConsoleDemo -ErrorAction SilentlyContinue
    Remove-Item env:M365_TOOLKIT_LOG_PATH -ErrorAction SilentlyContinue
}
Describe 'Console: plan, then run' {
    BeforeEach {
        $global:ConsoleCalls.Clear()
        Set-M365ChangeTarget -Service Exchange -Label 'contoso.onmicrosoft.com'
        Mock Write-Host { }
    }
    It 'dry runs, lists the change, and changes nothing unless the operator types yes' {
        Mock Read-Host { 'no' }
        Invoke-ReviewedCommand -Line "& '$($script:Task)' -Name 'Vendor'" -IsWrite $true -Interactive $false
        $global:ConsoleCalls.Count | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match "\[contoso.onmicrosoft.com\] Create thing 'Vendor'" }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match "New-FakeThing -Name 'Vendor'" }
    }
    It 'makes exactly the listed change after yes' {
        Mock Read-Host { 'yes' }
        Invoke-ReviewedCommand -Line "& '$($script:Task)' -Name 'Vendor'" -IsWrite $true -Interactive $false
        $global:ConsoleCalls | Should -Be @('New:Vendor')
    }
    It 'refuses a change the dry run did not show, even after yes' {
        Mock Read-Host { 'yes' }
        Invoke-ReviewedCommand -Line "& '$($script:Task)' -Name 'Vendor' -Sneaky" -IsWrite $true -Interactive $false
        $global:ConsoleCalls | Should -Be @('New:Vendor')
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'not in the reviewed plan' }
    }
    It 'runs a read-only task with an empty plan, so it cannot change anything' {
        Mock Read-Host { 'y' }
        Invoke-ReviewedCommand -Line "& '$($script:ReadOnly)' -Name 'Vendor'" -IsWrite $false -Interactive $false
        $global:ConsoleCalls.Count | Should -Be 0
    }
}
