<#
.SYNOPSIS
    Interactive menu for the AVD scripts in this repo. Sign in once, pick a pool, work.
.DESCRIPTION
    Run it with no arguments. It will:

      1. Sign you in (same browser/WAM popup as Connect-AzAccount) if you are not already
      2. Ask whether you are building a new environment or working with an existing one
      3. New: ask every question up front, show the plan, then run New-AvdEnvironment.ps1
         Existing: pick a subscription and host pool, then show the operations menu

    Each menu item asks for what it needs, remembers your answers for next time in this
    session, shows the exact parameters it is about to pass, offers a dry run (-WhatIf),
    and then calls the real script. No logic lives here. If you can do it in the menu,
    you can do it from the command line with the same script.
.PARAMETER TenantId
    Optional. Normally the console finds the right tenant itself and remembers it in
    console.local.json next to this script. Pass this to force a tenant.
.PARAMETER SubscriptionId
    Optional. Same: discovered and remembered unless you force it.
.PARAMETER ResourceGroupName
    With -HostPoolName, skip the host pool picker.
.PARAMETER HostPoolName
    With -ResourceGroupName, skip the host pool picker.
.EXAMPLE
    ./Start-AvdConsole.ps1
.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization, plus whatever each script needs
    Status:   Tested 2026-10-17 (sign-in, wizard, repair)
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Optional shortcuts so you can land straight on a pool.
#   WHY    Write-Host is normally banned in this repo (PSScriptAnalyzer flags it)
#          because it bypasses the pipeline. A console that talks to a human is the
#          one place it is correct, so the rule is suppressed for this file only.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console. Output is for the operator, not the pipeline.')]
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$', ErrorMessage = 'TenantId must be a GUID like 00000000-0000-0000-0000-000000000000.')]
    [string]$TenantId,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$HostPoolName
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Modules, script paths, and a hashtable that remembers answers.
#   WHY    $script:Remembered lets "add another host" reuse the subnet, gallery, and
#          domain you typed last time. It lives only for this run; nothing is written
#          to disk, so no client values ever land in the repo.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force
Import-Module (Join-Path $PSScriptRoot 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force
Import-Module (Join-Path $PSScriptRoot 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force
Import-Module (Join-Path $PSScriptRoot 'modules' 'ServerBuild' 'ServerBuild.psd1') -Force
Import-Module (Join-Path $PSScriptRoot 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force

$script:Scripts = @{
    NewHostPool  = Join-Path $PSScriptRoot 'avd' 'New-AvdHostPool.ps1'
    NewHost      = Join-Path $PSScriptRoot 'avd' 'New-AvdSessionHost.ps1'
    Drain        = Join-Path $PSScriptRoot 'avd' 'Set-AvdHostDrain.ps1'
    Reimage      = Join-Path $PSScriptRoot 'avd' 'Invoke-AvdHostReimage.ps1'
    Repair       = Join-Path $PSScriptRoot 'avd' 'Repair-AvdSessionHost.ps1'
    Teardown     = Join-Path $PSScriptRoot 'avd' 'Remove-AvdEnvironment.ps1'
    Backup       = Join-Path $PSScriptRoot 'backup' 'Enable-AvdBackup.ps1'
    Environment  = Join-Path $PSScriptRoot 'avd' 'New-AvdEnvironment.ps1'
    ShareAccess  = Join-Path $PSScriptRoot 'storage' 'Set-AvdProfileShareAccess.ps1'
    Power        = Join-Path $PSScriptRoot 'avd' 'Set-AvdHostPower.ps1'
    Rolling      = Join-Path $PSScriptRoot 'avd' 'Invoke-AvdRollingRestart.ps1'
    AgentWindow  = Join-Path $PSScriptRoot 'avd' 'Set-AvdAgentUpdateWindow.ps1'
    ScalingPlan  = Join-Path $PSScriptRoot 'avd' 'New-AvdScalingPlan.ps1'
    ScalingEdit  = Join-Path $PSScriptRoot 'avd' 'Set-AvdScalingPlan.ps1'
    ServerPower  = Join-Path $PSScriptRoot 'servers' 'Set-ServerPower.ps1'
    ServerNew    = Join-Path $PSScriptRoot 'servers' 'New-Server.ps1'
    ServerRole   = Join-Path $PSScriptRoot 'servers' 'Install-ServerRole.ps1'
    RdpGrant     = Join-Path $PSScriptRoot 'servers' 'Grant-ServerRdpAccess.ps1'
    RdpRevoke    = Join-Path $PSScriptRoot 'servers' 'Revoke-ServerRdpAccess.ps1'
    NetVNetNew   = Join-Path $PSScriptRoot 'network' 'New-NetVirtualNetwork.ps1'
    NetVNetSet   = Join-Path $PSScriptRoot 'network' 'Set-NetVirtualNetwork.ps1'
    NetSubnetNew = Join-Path $PSScriptRoot 'network' 'New-NetSubnet.ps1'
    NetSubnetSet = Join-Path $PSScriptRoot 'network' 'Set-NetSubnet.ps1'
    LabBicep     = Join-Path $PSScriptRoot '..' '..' 'infra' 'bicep' 'environments' 'lab' 'main.bicep'
}
$script:Remembered = @{}
$script:Pool = $null
#endregion

#region 3. Prompt helpers -----------------------------------------------------
#   WHAT   Small functions for asking questions: free text with a default, yes/no,
#          pick-from-a-list, and credentials.
#   WHY    Every menu action is "ask some questions, build a hashtable, run a script".
#          With these helpers each action reads as a list of questions.
#   GOTCHA Read-Host returns an empty string for Enter, never $null. Every helper
#          treats empty as "use the default".
function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Show-PromptHelp {
    <#
    .SYNOPSIS
        Explain the prompt conventions once, so nobody has to guess what Enter does.
    #>
    Write-Host ''
    Write-Host '  How prompts work:' -ForegroundColor Cyan
    Write-Host '    "(Enter = value)"  press Enter to accept that recommended default'
    Write-Host '    "(required)"       no default; you have to type something'
    Write-Host '    "(y/n, Enter = yes)" the word after Enter is what a blank answer means'
    Write-Host '    Numbered lists: the * marks the default; "Other" lets you type a value not listed'
    Write-Host '    Answers are remembered for the rest of this run and offered as defaults next time.'
}

function Read-Value {
    <#
    .SYNOPSIS
        Ask for a value. -Key remembers the answer for next time this run.
    #>
    param(
        [string]$Prompt,
        [string]$Key,
        [string]$Default,
        [switch]$Required
    )
    if ($Key -and $script:Remembered.ContainsKey($Key)) { $Default = $script:Remembered[$Key] }
    while ($true) {
        $label = if ($Default) { "$Prompt (Enter = $Default)" } else { "$Prompt (required)" }
        $answer = Read-Host $label
        if (-not $answer) { $answer = $Default }
        if ($Required -and -not $answer) {
            Write-Host '  Required.' -ForegroundColor Yellow
            continue
        }
        if ($Key -and $answer) { $script:Remembered[$Key] = $answer }
        return $answer
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { '(y/n, Enter = yes)' } else { '(y/n, Enter = no)' }
    $answer = Read-Host "$Prompt $hint"
    if (-not $answer) { return $Default }
    return $answer -match '^[Yy]'
}

function Select-Item {
    <#
    .SYNOPSIS
        Numbered picker. Returns the chosen item, or $null if the list is empty or
        the user enters nothing with -AllowNone.
    #>
    param(
        [string]$Title,
        [object[]]$Items,
        [scriptblock]$Label,
        [switch]$AllowNone,
        [int]$DefaultIndex = 0
    )
    if (-not $Items -or $Items.Count -eq 0) {
        Write-Host "  (nothing to choose from)" -ForegroundColor Yellow
        return $null
    }
    Write-Host "  $Title"
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $text = $Items[$i] | ForEach-Object $Label
        Write-Host ("  {0,3}. {1}" -f ($i + 1), $text)
    }
    $numberPrompt = if ($DefaultIndex -gt 0) { "  Number (Enter = $DefaultIndex)" } elseif ($AllowNone) { '  Number (Enter = none)' } else { '  Number (required)' }
    while ($true) {
        $answer = Read-Host $numberPrompt
        if (-not $answer -and $DefaultIndex -gt 0) { return $Items[$DefaultIndex - 1] }
        if (-not $answer -and $AllowNone) { return $null }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Items.Count) {
            return $Items[[int]$answer - 1]
        }
        Write-Host '  Pick a number from the list.' -ForegroundColor Yellow
    }
}

function Select-EntraGroup {
    <#
    .SYNOPSIS
        Search Entra groups by name prefix and pick one, or create a new one.
        Returns the group object ID, or $null. Remembers the answer under -Key.
    #>
    param([string]$Purpose, [string]$Key = 'userGroup')
    if ($script:Remembered.ContainsKey($Key)) {
        if (Read-YesNo "  Reuse group $($script:Remembered[$Key]) for $Purpose?" $true) { return $script:Remembered[$Key] }
    }
    while ($true) {
        $search = Read-Value "  Group name starts with (blank to skip, 'new' to create) for $Purpose"
        if (-not $search) { return $null }
        if ($search -eq 'new') {
            $name = Read-Value '  New group display name' -Required
            # Entra allows several groups with the same display name, so check first.
            # Without this, re-running the wizard silently creates a duplicate.
            $dupes = @(Get-AzADGroup -DisplayName $name -ErrorAction SilentlyContinue)
            if ($dupes.Count -gt 0) {
                Write-Host "  A group named '$name' already exists:" -ForegroundColor Yellow
                $g = Select-Item -Title 'Use one of these instead of creating a duplicate?' -Items $dupes -Label { "$($_.DisplayName)  ($($_.Id))  created $($_.CreatedDateTime)" } -AllowNone
                if ($g) {
                    $script:Remembered[$Key] = $g.Id
                    return $g.Id
                }
                if (-not (Read-YesNo "  Create ANOTHER group named '$name' anyway?" $false)) { continue }
            } elseif (-not (Read-YesNo "  Create security group '$name'?" $true)) { continue }
            $nick = ($name -replace '[^A-Za-z0-9]', '')
            $g = New-AzADGroup -DisplayName $name -MailNickname $nick -SecurityEnabled -Description 'AVD users'
            Write-Host "  Created $($g.DisplayName) ($($g.Id))" -ForegroundColor Green
            $script:Remembered[$Key] = $g.Id
            return $g.Id
        }
        $found = @(Get-AzADGroup -DisplayNameStartsWith $search | Sort-Object DisplayName | Select-Object -First 20)
        $g = Select-Item -Title "Groups matching '$search*'" -Items $found -Label { "$($_.DisplayName)  ($($_.Id))" } -AllowNone
        if ($g) {
            $script:Remembered[$Key] = $g.Id
            return $g.Id
        }
    }
}

function Read-Cred {
    <#
    .SYNOPSIS
        Credential dialog with a suggested user name, Azure policy check, and a
        confirmation prompt. Any failure sends you back to the dialog.
    #>
    param([string]$Message, [string]$Key, [string]$DefaultUserName = 'avdadmin')
    $user = if ($Key -and $script:Remembered.ContainsKey($Key)) { $script:Remembered[$Key] } else { $DefaultUserName }
    while ($true) {
        $cred = Get-Credential -Message "$Message (user name is a suggestion; change it in the dialog)" -UserName $user
        if (-not $cred) { throw 'Credential dialog was cancelled.' }
        $plain = $cred.GetNetworkCredential().Password

        $problems = @(Test-AvdVmCredentialPolicy -Credential $cred)   # @() because an empty return unrolls to $null
        if ($problems.Count -gt 0) {
            Write-Host '  Azure will reject this credential:' -ForegroundColor Yellow
            foreach ($pr in $problems) { Write-Host "    - $pr" -ForegroundColor Yellow }
            Write-Host '  Enter it again.' -ForegroundColor Yellow
            $user = $cred.UserName
            continue
        }

        $confirm = Read-Host "  Type the password for $($cred.UserName) again to confirm" -AsSecureString
        $confirmPlain = [System.Net.NetworkCredential]::new('', $confirm).Password
        if ($plain -cne $confirmPlain) {
            Write-Host '  Passwords do not match. Enter both again.' -ForegroundColor Yellow
            $user = $cred.UserName
            continue
        }

        if ($Key) { $script:Remembered[$Key] = $cred.UserName }
        return $cred
    }
}

function Read-Choice {
    <#
    .SYNOPSIS
        Numbered picker for a short list of values. Enter takes the default. -AllowOther
        adds "type a value" so the list never boxes you in.
    .PARAMETER Options
        Strings, or objects with Value and Label properties.
    #>
    param(
        [string]$Prompt,
        [object[]]$Options,
        [string]$Default,
        [string]$Key,
        [switch]$AllowOther
    )
    if ($Key -and $script:Remembered.ContainsKey($Key)) { $Default = $script:Remembered[$Key] }
    $values = @(foreach ($o in $Options) { if ($o -is [string]) { $o } else { $o.Value } })
    $defaultIndex = [array]::IndexOf($values, $Default) + 1

    Write-Host "  $Prompt"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $o = $Options[$i]
        $label = if ($o -is [string]) { $o } else { '{0,-22} {1}' -f $o.Value, $o.Label }
        $mark = if (($i + 1) -eq $defaultIndex) { '*' } else { ' ' }
        Write-Host ("  {0}{1,2}. {2}" -f $mark, ($i + 1), $label)
    }
    $otherIndex = $Options.Count + 1
    if ($AllowOther) { Write-Host ("   {0,2}. Other (type a value)" -f $otherIndex) }

    $hint = if ($defaultIndex -gt 0) { "Enter = $Default" } elseif ($Default -and $AllowOther) { "Enter = $Default" } else { 'required' }
    while ($true) {
        $answer = (Read-Host "  Number ($hint)").Trim()
        $chosen = $null
        if (-not $answer -and $Default) { $chosen = $Default }
        elseif ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Options.Count) { $chosen = $values[[int]$answer - 1] }
        elseif ($AllowOther -and $answer -match '^\d+$' -and [int]$answer -eq $otherIndex) { $chosen = Read-Value '  Value' -Required }
        elseif ($AllowOther -and $answer -and $answer -notmatch '^\d+$') { $chosen = $answer }   # typed the value directly
        if ($chosen) {
            if ($Key) { $script:Remembered[$Key] = $chosen }
            return $chosen
        }
        Write-Host '  Pick a number from the list.' -ForegroundColor Yellow
    }
}

function Get-VmSizeOptionList {
    <#
    .SYNOPSIS
        Curated session host sizes. Not exhaustive; "Other" covers the rest.
    #>
    @(
        [pscustomobject]@{ Value = 'Standard_D2s_v5';  Label = '2 vCPU, 8 GB.   Lab, 1-2 users' }
        [pscustomobject]@{ Value = 'Standard_D4s_v5';  Label = '4 vCPU, 16 GB.  Light office work, ~4-6 users per host' }
        [pscustomobject]@{ Value = 'Standard_D8s_v5';  Label = '8 vCPU, 32 GB.  ~8-12 users per host' }
        [pscustomobject]@{ Value = 'Standard_D16s_v5'; Label = '16 vCPU, 64 GB. Dense pooled hosts' }
        [pscustomobject]@{ Value = 'Standard_D4as_v5'; Label = '4 vCPU, 16 GB.  AMD, a bit cheaper than D4s' }
        [pscustomobject]@{ Value = 'Standard_D8as_v5'; Label = '8 vCPU, 32 GB.  AMD' }
        [pscustomobject]@{ Value = 'Standard_E4s_v5';  Label = '4 vCPU, 32 GB.  Memory-heavy apps' }
        [pscustomobject]@{ Value = 'Standard_E8s_v5';  Label = '8 vCPU, 64 GB.  Memory-heavy apps' }
    )
}

function Get-VmSizeCatalog {
    <#
    .SYNOPSIS
        Sizes offered in a region with vCPU quota, from the module. Cached per region
        for this run. Families with 0 quota are left out: they fail at VM creation.
    #>
    param([string]$Location)
    if (-not (Get-Variable -Name VmSizeCache -Scope Script -ErrorAction SilentlyContinue)) { $script:VmSizeCache = @{} }
    if ($script:VmSizeCache.ContainsKey($Location)) { return $script:VmSizeCache[$Location] }
    $catalog = @(Get-AvdVmSizeCatalog -Location $Location)
    $script:VmSizeCache[$Location] = $catalog
    return $catalog
}

function Select-VmSize {
    <#
    .SYNOPSIS
        Pick a VM size by walking family > CPU vendor > version > size, from the
        sizes actually offered in the region. Enter at every level lands on -Default.
    #>
    param([string]$Location, [string]$Default = 'Standard_D4s_v5', [string]$Key = 'vmSize')
    if ($Key -and $script:Remembered.ContainsKey($Key)) { $Default = $script:Remembered[$Key] }

    $catalog = $null
    if ($Location) {
        try { $catalog = Get-VmSizeCatalog -Location $Location }
        catch { Write-Host "  (could not list VM sizes in ${Location}: $($_.Exception.Message); using a fixed list)" -ForegroundColor DarkGray }
    }
    if (-not $catalog) {
        return Read-Choice -Prompt 'VM size' -Key $Key -Default $Default -Options (Get-VmSizeOptionList) -AllowOther
    }

    # The module already drops ARM, non-premium-disk and zero-quota sizes.
    $usable = @($catalog)
    Write-Host '  Sizes whose family has no vCPU quota in this region are not listed.' -ForegroundColor DarkGray
    $def = $usable | Where-Object Name -eq $Default | Select-Object -First 1

    $familyInfo = [ordered]@{
        D  = 'General purpose. 4 GB per vCPU. The AVD default.'
        E  = 'Memory optimized. 8 GB per vCPU. Memory-heavy apps.'
        F  = 'Compute optimized. 2 GB per vCPU. CPU-bound work, light memory.'
        B  = 'Burstable. Cheap, credit-based CPU. Lab and test only.'
        NV = 'GPU for graphics. CAD, video, 3D. Expensive.'
        DC = 'Confidential computing. Hardware-encrypted memory. Rare for AVD.'
    }
    $present = @($usable | Select-Object -ExpandProperty Family -Unique)
    $familyOptions = @(foreach ($f in $familyInfo.Keys) { if ($f -in $present) { [pscustomobject]@{ Value = $f; Label = $familyInfo[$f] } } })
    $others = @($present | Where-Object { $_ -notin $familyInfo.Keys } | Sort-Object)
    if ($others.Count -gt 0) { $familyOptions += [pscustomobject]@{ Value = 'Other'; Label = "Other families: $($others -join ', ')" } }

    # 1. Family
    $family = Read-Choice -Prompt 'VM family' -Default $(if ($def) { $def.Family } else { 'D' }) -Options $familyOptions
    if ($family -eq 'Other') { $family = Read-Choice -Prompt 'Family' -Default $others[0] -Options $others }
    $inFamily = @($usable | Where-Object Family -eq $family)

    # 2. CPU vendor (skipped when the family only has one)
    $cpus = @($inFamily | Select-Object -ExpandProperty Cpu -Unique | Sort-Object)
    $cpu = if ($cpus.Count -eq 1) { Write-Host "  CPU: $($cpus[0]) (only option in $family)"; $cpus[0] } else {
        $cpuOptions = @(foreach ($c in $cpus) {
            $hint = switch ($c) { 'Intel' { 'No vendor letter in the name.' } 'AMD' { 'Letter "a" in the name. Usually a bit cheaper per vCPU.' } default { '' } }
            [pscustomobject]@{ Value = $c; Label = $hint }
        })
        Read-Choice -Prompt 'CPU' -Default $(if ($def -and $def.Family -eq $family) { $def.Cpu } else { 'Intel' }) -Options $cpuOptions
    }
    $inCpu = @($inFamily | Where-Object Cpu -eq $cpu)

    # 3. Version (skipped when there is only one)
    $versions = @($inCpu | Select-Object -ExpandProperty Version -Unique | Sort-Object -Descending)
    $version = if ($versions.Count -eq 1) { Write-Host "  Version: v$($versions[0]) (only option)"; $versions[0] } else {
        $verOptions = @(foreach ($v in $versions) {
            [pscustomobject]@{ Value = "$v"; Label = $(if ($v -eq $versions[0]) { 'Newest generation. Best price for performance.' } else { 'Older generation.' }) }
        })
        [int](Read-Choice -Prompt 'Version' -Default $(if ($def -and $def.Family -eq $family -and $def.Cpu -eq $cpu) { "$($def.Version)" } else { "$($versions[0])" }) -Options $verOptions)
    }
    $inVersion = @($inCpu | Where-Object Version -eq $version | Sort-Object Cores, Name)

    # 4. Size
    $sizeOptions = @(foreach ($s in $inVersion) {
        $hints = @()
        if ($s.Features -like '*d*') { $hints += 'local temp disk' }
        if ($s.Features -like '*l*') { $hints += 'low memory' }
        if ($s.Features -like '*m*' -and $s.Family -ne 'B') { $hints += 'high memory' }
        if ($s.Accelerator) { $hints += "GPU $($s.Accelerator)" }
        $label = '{0,2} vCPU, {1,3} GB' -f $s.Cores, $s.MemoryGB
        if ($hints.Count -gt 0) { $label += "  (" + ($hints -join ', ') + ')' }
        if ($null -ne $s.QuotaLimit) { $label += "  quota $($s.QuotaAvailable)/$($s.QuotaLimit) vCPU free" }
        [pscustomobject]@{ Value = $s.Name; Label = $label }
    })
    $sizeDefault = if ($def -and $def.Name -in $inVersion.Name) { $def.Name } else {
        $pick = $inVersion | Where-Object { $_.Cores -eq 4 -and $_.Features -notlike '*d*' -and $_.Features -notlike '*l*' } | Select-Object -First 1
        if ($pick) { $pick.Name } else { $inVersion[0].Name }
    }
    $size = Read-Choice -Prompt "Size ($family, $cpu, v$version)" -Default $sizeDefault -Options $sizeOptions -AllowOther
    if ($Key) { $script:Remembered[$Key] = $size }
    return $size
}

function Get-ImageSkuOptionList {
    <#
    .SYNOPSIS
        Windows multi-session + Microsoft 365 Apps SKUs, queried live from the
        marketplace so new releases appear on their own. Falls back to a fixed list
        if the query fails (no location yet, no network).
    #>
    param([string]$Location)
    $skus = @()
    if ($Location) {
        try {
            $skus = @(Get-AzVMImageSku -Location $Location -PublisherName 'MicrosoftWindowsDesktop' -Offer 'office-365' -ErrorAction Stop |
                Select-Object -ExpandProperty Skus |
                Where-Object { $_ -match '^win1[01]-\d\dh\d-avd-m365$' } |
                Sort-Object -Descending)
        } catch {
            Write-Host "  (could not query marketplace SKUs: $($_.Exception.Message); using a fixed list)" -ForegroundColor DarkGray
        }
    }
    if ($skus.Count -eq 0) { $skus = @('win11-25h2-avd-m365', 'win11-24h2-avd-m365', 'win11-23h2-avd-m365', 'win10-22h2-avd-m365') }
    foreach ($s in $skus) {
        $label = if ($s -match '^win(1[01])-(\d\dh\d)-avd-m365$') { "Windows $($Matches[1]) $($Matches[2].ToUpper()) multi-session + Microsoft 365 Apps" } else { $s }
        [pscustomobject]@{ Value = $s; Label = $label }
    }
}
#endregion

#region 4. Script runner ------------------------------------------------------
#   WHAT   Show the parameters, offer a dry run, confirm, run, show the result.
#   WHY    One place that every action goes through. Tokens and passwords are masked
#          in the preview; credentials show only the username.
#   GOTCHA Errors are caught here so one failed action does not kill the console.
#          The full error is printed; re-run the script by hand with -Verbose to dig in.
function Invoke-RepoScript {
    param(
        [string]$Path,
        [hashtable]$Params,
        [switch]$Destructive
    )
    Write-Host ''
    Write-Host "  About to run $(Split-Path $Path -Leaf) with:" -ForegroundColor Cyan
    foreach ($k in ($Params.Keys | Sort-Object)) {
        $v = $Params[$k]
        $shown = switch ($true) {
            ($v -is [pscredential]) { "<credential: $($v.UserName)>"; break }
            ($k -like '*Token*')    { '<hidden>'; break }
            ($v -is [hashtable])    { ($v.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '; break }
            default                 { "$v" }
        }
        Write-Host ("    {0,-28} {1}" -f $k, $shown)
    }

    if (Read-YesNo '  Dry run first (-WhatIf)?' $false) {
        $dry = $Params.Clone()
        $dry.WhatIf = $true
        & $Path @dry | Out-Host
        if (-not (Read-YesNo '  Now run it for real?' $false)) { return }
    } elseif (-not (Read-YesNo '  Proceed?' (-not $Destructive))) {
        return
    }

    try {
        $Params.Verbose = $true
        $result = & $Path @Params
        if ($result) { $result | Format-List | Out-Host }
        Write-Host '  Done.' -ForegroundColor Green
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ScriptStackTrace) { Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray }
    }
}
#endregion

#region 5. Sign in and pick scope --------------------------------------------
#   WHAT   Login (popup if needed), subscription picker, host pool picker.
#   WHY    Assert-AzContext is the same call every script makes. If you are already
#          signed in from an earlier script there is no popup. The pickers mean you
#          never type a subscription or pool name.
$script:LocalConfigPath = Join-Path $PSScriptRoot 'console.local.json'   # *.local.* is gitignored

function Get-LocalConfig {
    if (Test-Path $script:LocalConfigPath) {
        try { return Get-Content $script:LocalConfigPath -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Save-LocalConfig {
    param([string]$Account, [string]$TenantId, [string]$SubscriptionId, [string]$SubscriptionName)
    [pscustomobject]@{
        account          = $Account
        tenantId         = $TenantId
        subscriptionId   = $SubscriptionId
        subscriptionName = $SubscriptionName
        savedAt          = (Get-Date).ToString('u')
    } | ConvertTo-Json | Set-Content $script:LocalConfigPath
}

function Switch-ContextTo {
    <#
    .SYNOPSIS
        Point the Az context at a tenant + subscription, signing in to that tenant
        interactively if a silent switch is refused (fresh MFA, conditional access).
    #>
    param([string]$TenantId, [string]$SubscriptionId)
    try {
        return Set-AzContext -Tenant $TenantId -Subscription $SubscriptionId -ErrorAction Stop
    } catch {
        Write-Host "  That tenant wants a fresh sign-in ($($_.Exception.Message.Split([char]10)[0]))." -ForegroundColor DarkGray
        $null = Connect-AzAccount -TenantId $TenantId -Subscription $SubscriptionId -ErrorAction Stop
        return Get-AzContext
    }
}

function Initialize-ConsoleSession {
    <#
    .SYNOPSIS
        Get a usable Az context with a subscription, however the account is shaped,
        without the person having to know tenant IDs.
    .DESCRIPTION
        1. Disable the Windows token broker for this process only (it is what produces
           "SharedTokenCacheCredential authentication failed"). Global config untouched.
        2. Reuse an existing sign-in that already has a subscription, after a yes/no.
        3. Otherwise sign in, preferring the tenant/subscription remembered from last
           time or passed on the command line.
        4. If the sign-in has no subscription (personal accounts land in a consumer
           directory that holds none), discover subscriptions across every tenant
           the account can see and pick, or ask.
        5. Remember the result in console.local.json.
    #>
    param([string]$TenantId, [string]$SubscriptionId)

    try { $null = Update-AzConfig -EnableLoginByWam $false -Scope Process -WarningAction SilentlyContinue -ErrorAction Stop }
    catch { Write-Verbose "Could not disable WAM for this process: $($_.Exception.Message)" }

    $saved = Get-LocalConfig
    $wantTenant = if ($TenantId) { $TenantId } elseif ($saved) { $saved.tenantId } else { $null }
    $wantSub    = if ($SubscriptionId) { $SubscriptionId } elseif ($saved -and -not $TenantId) { $saved.subscriptionId } else { $null }

    # 2. Existing context
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx -and $ctx.Subscription -and $ctx.Subscription.Id) {
        $fits = (-not $wantTenant -or $ctx.Tenant.Id -eq $wantTenant) -and (-not $wantSub -or $ctx.Subscription.Id -eq $wantSub)
        if ($fits -and (Read-YesNo "  Already signed in as $($ctx.Account.Id), subscription '$($ctx.Subscription.Name)'. Use it?" $true)) {
            Save-LocalConfig -Account $ctx.Account.Id -TenantId $ctx.Tenant.Id -SubscriptionId $ctx.Subscription.Id -SubscriptionName $ctx.Subscription.Name
            return $ctx
        }
        $ctx = $null
    }

    # 3. Sign in
    if ($saved -and -not $TenantId) {
        Write-Host "  Last time: $($saved.account), subscription '$($saved.subscriptionName)'." -ForegroundColor DarkGray
    }
    Write-Host '  A browser window will open for sign-in.'
    $connect = @{ ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if ($wantTenant) { $connect.TenantId = $wantTenant }
    if ($wantSub)    { $connect.Subscription = $wantSub }
    try {
        $null = Connect-AzAccount @connect
    } catch {
        # A remembered tenant/subscription may no longer be reachable; fall back to a plain sign-in.
        if ($wantTenant -or $wantSub) {
            Write-Host "  Sign-in with the remembered tenant failed ($($_.Exception.Message.Split([char]10)[0])). Trying without it." -ForegroundColor Yellow
            $null = Connect-AzAccount -ErrorAction Stop -WarningAction SilentlyContinue
        } else { throw }
    }
    $ctx = Get-AzContext

    # 4. No subscription: discover across tenants
    if (-not ($ctx -and $ctx.Subscription -and $ctx.Subscription.Id)) {
        Write-Host '  That sign-in has no subscription in its directory. Looking across your tenants...'
        $choices = @(Find-AzSubscriptionAcrossTenant -Verbose:($VerbosePreference -eq 'Continue'))
        if ($choices.Count -eq 0) {
            # Silent discovery found nothing. Usual cause: the tenant that holds the
            # subscription needs its own interactive sign-in (always true for a
            # personal account reaching its Default Directory). Offer that.
            $tenants = @(Get-AzTenant -ErrorAction SilentlyContinue)
            if ($tenants.Count -eq 0) {
                throw "Signed in as $($ctx.Account.Id) but this account cannot see any Azure tenant. Is the lab subscription on a different account?"
            }
            Write-Host '  No subscription was reachable without a direct sign-in. Tenants this account can see:'
            $target = if ($tenants.Count -eq 1) {
                Write-Host "    $($tenants[0].Name)  ($($tenants[0].Id))"
                $tenants[0]
            } else {
                Select-Item -Title 'Sign in to which tenant?' -Items $tenants -Label { "$($_.Name)  ($($_.Id))" }
            }
            if (-not $target) { throw 'No tenant chosen.' }
            Write-Host "  Signing in to $($target.Name)... (browser)"
            $null = Connect-AzAccount -TenantId $target.Id -ErrorAction Stop -WarningAction SilentlyContinue
            $subs = @(Get-AzSubscription -TenantId $target.Id -WarningAction SilentlyContinue | Where-Object State -eq 'Enabled')
            if ($subs.Count -eq 0) {
                throw "Signed in to tenant $($target.Name) but it has no enabled subscription for $($ctx.Account.Id)."
            }
            $choices = @(foreach ($sub in $subs) {
                [pscustomobject]@{ TenantId = $target.Id; TenantName = $target.Name; SubscriptionId = $sub.Id; SubscriptionName = $sub.Name }
            })
        }
        $pick = if ($choices.Count -eq 1) { $choices[0] } else {
            Select-Item -Title 'Subscriptions you can reach' -Items $choices -Label { "$($_.SubscriptionName)  in $($_.TenantName)  ($($_.SubscriptionId))" }
        }
        $ctx = Switch-ContextTo -TenantId $pick.TenantId -SubscriptionId $pick.SubscriptionId
    }

    Save-LocalConfig -Account $ctx.Account.Id -TenantId $ctx.Tenant.Id -SubscriptionId $ctx.Subscription.Id -SubscriptionName $ctx.Subscription.Name
    return $ctx
}

function Select-Subscription {
    # Everything the account can reach, across tenants; switching tenants signs in
    # to that tenant if Azure insists.
    $choices = @(Find-AzSubscriptionAcrossTenant | Sort-Object TenantName, SubscriptionName)
    $pick = Select-Item -Title 'Subscriptions you can reach' -Items $choices -Label { "$($_.SubscriptionName)  in $($_.TenantName)  ($($_.SubscriptionId))" } -AllowNone
    if ($pick) {
        $ctx = Switch-ContextTo -TenantId $pick.TenantId -SubscriptionId $pick.SubscriptionId
        $script:SubscriptionId = $ctx.Subscription.Id
        $script:Pool = $null
        Save-LocalConfig -Account $ctx.Account.Id -TenantId $ctx.Tenant.Id -SubscriptionId $ctx.Subscription.Id -SubscriptionName $ctx.Subscription.Name
    }
}

function Select-HostPool {
    $pools = @(Get-AzWvdHostPool | Sort-Object Name)
    $pool = Select-Item -Title 'Host pools in this subscription' -Items $pools -Label {
        "$($_.Name)  [$($_.HostPoolType)/$($_.LoadBalancerType)]  rg: $(($_.Id -split '/')[4])"
    } -AllowNone
    if ($pool) {
        $script:Pool = @{
            Name              = $pool.Name
            ResourceGroupName = ($pool.Id -split '/')[4]
            Type              = $pool.HostPoolType
        }
    }
}

function Select-SessionHost {
    param([string]$Title = 'Session hosts')
    $hosts = @(Get-AvdSessionHostInfo -ResourceGroupName $script:Pool.ResourceGroupName -HostPoolName $script:Pool.Name | Sort-Object Name)
    Select-Item -Title $Title -Items $hosts -Label {
        $drain = if ($_.Drain) { 'DRAIN' } else { '     ' }
        "{0,-32} {1,-16} {2} sessions={3}" -f $_.Name, $_.Status, $drain, $_.Sessions
    }
}

Write-Title 'Azure Virtual Desktop console'
Show-PromptHelp
Write-Host ''
$ctx = Initialize-ConsoleSession -TenantId $TenantId -SubscriptionId $SubscriptionId
$script:SubscriptionId = $ctx.Subscription.Id
Write-Host "  Signed in as $($ctx.Account.Id), subscription '$($ctx.Subscription.Name)' ($($ctx.Subscription.Id))" -ForegroundColor Green
Write-Host "  Remembered in $script:LocalConfigPath (gitignored). Option S switches subscription." -ForegroundColor DarkGray

if ($ResourceGroupName -and $HostPoolName) {
    $script:Pool = @{ Name = $HostPoolName; ResourceGroupName = $ResourceGroupName; Type = '?' }
}
#endregion

#region 6. Menu actions -------------------------------------------------------
#   WHAT   One function per menu line. Each asks its questions and calls the runner.
#   WHY    Reading these top to bottom is the same as reading the scripts' parameter
#          lists. If a script grows a parameter, add one Read-Value line here.
function Show-PermissionReport {
    <#
    .SYNOPSIS
        What this account can and cannot do for an AVD build, as a table.
    #>
    param([string]$ResourceGroupName, [bool]$IncludeBackup = $false)
    Write-Title 'Permission check'
    Write-Host "  Checking $((Get-AzContext).Account.Id) against what the build needs..."
    $report = @(Test-AvdBuildPermission -SubscriptionId $script:SubscriptionId -ResourceGroupName $ResourceGroupName -IncludeBackup:$IncludeBackup)
    foreach ($r in $report) {
        $mark = if ($null -eq $r.Granted) { '?' } elseif ($r.Granted) { 'OK ' } else { 'NO ' }
        $color = if ($null -eq $r.Granted) { 'DarkGray' } elseif ($r.Granted) { 'Green' } elseif ($r.Required) { 'Red' } else { 'Yellow' }
        $line = '  {0} {1,-10} {2,-55} {3}' -f $mark, $r.Area, $r.Capability, $(if ($r.Granted) { "($($r.Scope))" } else { "fix: $($r.FixWith)" })
        Write-Host $line -ForegroundColor $color
    }
    $missing = @($report | Where-Object { $_.Required -and $_.Granted -eq $false })
    if ($missing.Count -gt 0) {
        Write-Host "  $($missing.Count) required permission(s) missing. The build will fail at those steps." -ForegroundColor Red
    } else {
        Write-Host '  All required permissions present.' -ForegroundColor Green
    }
    return ($missing.Count -eq 0)
}

function Invoke-PrepareSubscription {
    Write-Title 'Register resource providers'
    $providers = @(
        'Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage',
        'Microsoft.RecoveryServices', 'Microsoft.Automation', 'Microsoft.OperationalInsights', 'Microsoft.Insights',
        'Microsoft.KeyVault', 'Microsoft.ManagedIdentity'
    )
    Write-Host "  $($providers -join "`n  ")"
    if (-not (Read-YesNo '  Register any of these that are missing?' $true)) { return }
    try {
        Assert-AzResourceProvider -Namespace $providers -Verbose
        Write-Host '  All registered.' -ForegroundColor Green
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-DeployLab {
    <#
    .SYNOPSIS
        Deploy infra/bicep/environments/lab/main.bicep and remember its outputs.
    #>
    Write-Title 'Deploy lab infrastructure (Bicep)'
    Write-Host '  Needs the Bicep CLI on PATH (az bicep install, or winget install Microsoft.Bicep).'
    $rg       = Read-Value 'Resource group' -Key 'rg' -Required
    $location = Read-Value 'Location' -Key 'location' -Required
    $params = @{
        environment         = Read-Value 'Environment label' -Default 'lab'
        addressPrefix       = Read-Value 'VNet address space' -Default '10.10.0.0/16'
        subnetPrefix        = Read-Value 'Session host subnet' -Default '10.10.1.0/24'
        deployProfileStorage = (Read-YesNo 'Deploy FSLogix profile storage?' $true)
        deployGallery       = (Read-YesNo 'Deploy a Compute Gallery for custom images?' $false)
    }
    if ($params.deployProfileStorage) {
        $params.storageAccountName = Read-Value 'Storage account name (globally unique, lowercase)' -Key 'profileSa' -Default "stavd$($params.environment)prof01" -Required
        $params.storageSkuName     = Read-Value 'Storage SKU (Premium_LRS/Standard_LRS)' -Default 'Standard_LRS'
        $params.profileShareName   = Read-Value 'Share name' -Key 'profileShare' -Default 'profiles'
    }
    if ($params.deployGallery) {
        $params.galleryName         = Read-Value 'Gallery name (no hyphens)' -Key 'gallery' -Default "gal_avd_$($params.environment)"
        $params.imageDefinitionName = Read-Value 'Image definition name' -Key 'imageDef' -Default 'win11-avd-m365'
    }

    if (-not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)) {
        if (Read-YesNo "  Resource group $rg does not exist. Create it in $location?" $true) {
            $null = New-AzResourceGroup -Name $rg -Location $location
        } else { return }
    }

    Write-Host "  Parameters:" -ForegroundColor Cyan
    foreach ($k in ($params.Keys | Sort-Object)) { Write-Host ("    {0,-24} {1}" -f $k, $params[$k]) }
    if (Read-YesNo '  Preview with what-if first?' $true) {
        New-AzResourceGroupDeployment -ResourceGroupName $rg -TemplateFile $script:Scripts.LabBicep -TemplateParameterObject $params -WhatIf
        if (-not (Read-YesNo '  Deploy for real?' $false)) { return }
    } elseif (-not (Read-YesNo '  Deploy?' $true)) { return }

    try {
        $d = New-AzResourceGroupDeployment -ResourceGroupName $rg -TemplateFile $script:Scripts.LabBicep -TemplateParameterObject $params -Name "lab-$(Get-Date -Format yyyyMMddHHmm)"
        Write-Host "  Deployment $($d.ProvisioningState)." -ForegroundColor Green
        # Pre-fill later prompts with what was just built.
        if ($d.Outputs.subnetId)        { $script:Remembered['subnet']  = $d.Outputs.subnetId.Value }
        if ($d.Outputs.profileShareUnc -and $d.Outputs.profileShareUnc.Value) { $script:Remembered['fslogix'] = $d.Outputs.profileShareUnc.Value }
        if ($d.Outputs.galleryName -and $d.Outputs.galleryName.Value) {
            $script:Remembered['galleryRg']   = $rg
            $script:Remembered['gallery']     = $d.Outputs.galleryName.Value
            $script:Remembered['imageDef']    = $d.Outputs.imageDefinitionName.Value
            $script:Remembered['imageSource'] = 'Gallery'
        }
        $d.Outputs.GetEnumerator() | ForEach-Object { Write-Host ("    {0,-24} {1}" -f $_.Key, $_.Value.Value) }
        if ($params.deployProfileStorage) {
            Write-Host '  Next: option B to set NTFS permissions and see the admin-consent step.' -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-ShareAccess {
    Write-Title 'Configure profile share access (Entra Kerberos)'
    $p = @{
        SubscriptionId     = $script:SubscriptionId
        ResourceGroupName  = Read-Value 'Storage account resource group' -Key 'rg' -Required
        StorageAccountName = Read-Value 'Storage account' -Key 'profileSa' -Required
        ShareName          = Read-Value 'Share name' -Key 'profileShare' -Default 'profiles'
    }
    if (Read-YesNo 'Also grant a user group on the share (not needed with the default share permission)?' $false) {
        $g = Select-EntraGroup -Purpose 'share access'
        if ($g) { $p.UserGroupObjectId = $g }
    }
    if (Read-YesNo 'Grant an admin group Elevated Contributor (can fix NTFS from a host)?' $false) {
        $g = Select-EntraGroup -Purpose 'share admin' -Key 'adminGroup'
        if ($g) { $p.AdminGroupObjectId = $g }
    }
    $via = Read-Choice -Prompt 'Apply FSLogix NTFS permissions' -Default 'SessionHost' -Options @(
        [pscustomobject]@{ Value = 'SessionHost'; Label = 'From a session host in the pool (Run Command). Works regardless of your ISP.' }
        [pscustomobject]@{ Value = 'Local';       Label = 'From this machine. Needs outbound TCP 445.' }
        [pscustomobject]@{ Value = 'Skip';        Label = 'Do not touch NTFS.' }
    )
    if ($via -ne 'Skip') {
        $p.SetNtfsPermissions = $true
        $p.NtfsVia = $via
        if ($via -eq 'SessionHost') {
            if (-not $script:Pool) { Write-Host '  Pick a host pool first (P) so a session host can be chosen.' -ForegroundColor Yellow; return }
            $h = Select-SessionHost -Title 'Run the NTFS step on which host'
            if (-not $h) { return }
            $vmRes = Get-AzResource -ResourceId $h.VmResourceId
            $p.ViaVMName = $vmRes.Name
            $p.ViaVMResourceGroupName = $vmRes.ResourceGroupName
        }
    }
    Invoke-RepoScript -Path $script:Scripts.ShareAccess -Params $p
    $script:Remembered['fslogix'] = "\\$($p.StorageAccountName).file.core.windows.net\$($p.ShareName)"
}

function Show-PoolStatus {
    Write-Title "Host pool $($script:Pool.Name)"
    $o = Get-AvdHostPoolOverview -ResourceGroupName $script:Pool.ResourceGroupName -HostPoolName $script:Pool.Name -IncludePrice
    Write-Host ("  {0} ({1}, {2}, max {3} sessions/host) in {4}" -f $o.Pool.Name, $o.Pool.Type, $o.Pool.LoadBalancer, $o.Pool.MaxSessionLimit, $o.Pool.Location)
    Write-Host ("  Start VM On Connect: {0}   Agent updates: {1}" -f $(if ($o.Pool.StartVMOnConnect) { 'on' } else { 'off' }), $o.Pool.AgentUpdate)
    Write-Host ("  Hosts: {0} total, {1} available, {2} unavailable, {3} drained.  Sessions: {4}.  VMs running: {5}, deallocated: {6}." -f
        $o.Counts.Total, $o.Counts.Available, $o.Counts.Unavailable, $o.Counts.Drained, $o.Counts.Sessions, $o.Counts.Running, $o.Counts.Deallocated)
    if (@($o.ScalingPlans).Count -gt 0) {
        foreach ($p in $o.ScalingPlans) { Write-Host "  Scaling plan: $($p.Name) ($(if ($p.Enabled) { 'enabled' } else { 'attached, disabled' }), $($p.TimeZone))" -ForegroundColor Green }
    } else {
        Write-Host '  Scaling plan: none. Hosts run until someone stops them (option 11).' -ForegroundColor Yellow
    }
    if ($o.Cost) {
        Write-Host ('  Compute estimate: ${0:n0}/month if every host runs 24x7, ${1:n0}/month at 10 hours on weekdays. Compute only.' -f $o.Cost.Monthly24x7Usd, $o.Cost.MonthlyBusinessHoursUsd) -ForegroundColor DarkGray
    }
    $o.Hosts | Format-Table Name, Status, PowerState, Drain, Sessions, VMSize, AgentVersion, LastHeartBeat -AutoSize | Out-Host
}

function Invoke-HostPower {
    Write-Title 'Host power'
    $sessionHost = Select-SessionHost -Title 'Which host?'
    if (-not $sessionHost) { return }
    $action = Read-Choice -Prompt 'Action' -Default 'Start' -Options @(
        [pscustomobject]@{ Value = 'Start';      Label = 'Power the VM on.' }
        [pscustomobject]@{ Value = 'Deallocate'; Label = 'Stop and deallocate (stops billing). Refused while users are signed in.' }
        [pscustomobject]@{ Value = 'Restart';    Label = 'Restart. Refused while users are signed in.' }
        [pscustomobject]@{ Value = 'Stop';       Label = 'Power off but keep allocated (still billed). Rarely wanted.' }
    )
    $p = @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $script:Pool.ResourceGroupName; HostPoolName = $script:Pool.Name; SessionHostName = @($sessionHost.Name); Action = $action }
    if ($action -ne 'Start' -and $sessionHost.Sessions -gt 0 -and (Read-YesNo "  $($sessionHost.Name) has $($sessionHost.Sessions) session(s). Force it anyway?" $false)) { $p.Force = $true }
    Invoke-RepoScript -Path $script:Scripts.Power -Params $p
}

function Invoke-RollingRestart {
    Write-Title "Rolling restart of $($script:Pool.Name)"
    Write-Host '  Per host, one at a time: drain, message users, wait, restart, wait for Available, undrain.'
    $p = @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $script:Pool.ResourceGroupName; HostPoolName = $script:Pool.Name }
    if (-not (Read-YesNo '  Every host in the pool?' $true)) {
        $one = Select-SessionHost -Title 'Which host?'
        if (-not $one) { return }
        $p.SessionHostName = @($one.Name)
    }
    $p.WaitMinutes = [int](Read-Value 'Minutes to wait for users to leave each host' -Default '30')
    $p.MessageBody = Read-Value 'Message to active users' -Default "This desktop will restart for maintenance in $($p.WaitMinutes) minutes. Please save your work and sign out."
    if (Read-YesNo '  Log off users still signed in when the wait runs out? (No = skip that host)' $false) { $p.ForceLogoff = $true }
    if (Read-YesNo '  Also restart hosts that are not Available?' $false) { $p.IncludeUnavailable = $true }
    Invoke-RepoScript -Path $script:Scripts.Rolling -Params $p
}

function Invoke-AgentWindow {
    Write-Title 'Agent update window'
    $p = @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $script:Pool.ResourceGroupName; HostPoolName = $script:Pool.Name }
    if (Read-YesNo '  Back to Microsoft default timing instead of a window?' $false) {
        $p.Default = $true
    } else {
        $p.DayOfWeek = Read-Choice -Prompt 'Day' -Default 'Saturday' -Options @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
        $p.Hour = [int](Read-Value 'Start hour (0-23, two-hour window)' -Default '2')
        if (Read-YesNo "  Use each host's local time instead of a fixed time zone?" $false) { $p.UseSessionHostLocalTime = $true }
        else { $p.TimeZone = Read-Value 'Time zone (Windows ID)' -Default (Get-TimeZone).Id }
    }
    Invoke-RepoScript -Path $script:Scripts.AgentWindow -Params $p
}

function Read-ServerRole {
    # Role questions shared by new-server and install-role. Returns a hashtable of script parameters.
    param([string]$Default = 'None')
    $p = @{}
    $p.Role = Read-Choice -Prompt 'Role' -Default $Default -Options @(
        [pscustomobject]@{ Value = 'None';     Label = 'Plain Windows Server.' }
        [pscustomobject]@{ Value = 'IIS';      Label = 'Web server: IIS with management console and ASP.NET 4.8.' }
        [pscustomobject]@{ Value = 'ADForest'; Label = 'First domain controller of a new forest (AD DS + DNS).' }
        [pscustomobject]@{ Value = 'SQL';      Label = 'Configure a SQL Server marketplace image (folders, mixed mode, firewall).' }
    )
    switch ($p.Role) {
        'ADForest' {
            $p.DomainName = Read-Value 'Domain DNS name (two or more labels, e.g. corp.example.com)' -Required
            $nb = Read-Value 'NetBIOS name' -Default (($p.DomainName -split '\.')[0].ToUpperInvariant())
            if ($nb) { $p.NetbiosName = $nb }
            $p.SafeModeCredential = Read-Cred -Message 'Directory Services Restore Mode (DSRM) password; the user name is ignored' -Key 'dsrm'
            if (Read-YesNo '  Point the VNet DNS at this DC? (live change; other VMs pick it up on restart)' $false) { $p.SetVNetDns = $true }
        }
        'SQL' {
            if (Read-YesNo '  Enable mixed-mode authentication and set the sa password?' $false) { $p.SaCredential = Read-Cred -Message 'sa password; the user name is ignored' -Key 'sa' }
            $p.SqlLicenseType = Read-Choice -Prompt 'SQL licence for the IaaS registration' -Default 'PAYG' -Options @('PAYG', 'AHUB', 'DR')
        }
    }
    return $p
}

function Invoke-ServerInventory {
    Write-Title 'Servers'
    $rg = Read-Value 'Resource group (blank = whole subscription)' -Key 'serverRg'
    $p = @{}
    if ($rg) { $p.ResourceGroupName = $rg }
    $vms = @(Get-ServerVmInfo @p | Sort-Object ResourceGroupName, Name)
    if ($vms.Count -eq 0) { Write-Host '  No VMs.'; return }
    $vms | Format-Table Name, ResourceGroupName, PowerState, VMSize, Image, PrivateIp, Role -AutoSize | Out-Host
    if (-not (Read-YesNo '  Change power state on one of them?' $false)) { return }
    $vm = Select-Item -Title 'Which VM?' -Items $vms -Label { "$($_.Name)  $($_.PowerState)  ($($_.ResourceGroupName))" } -AllowNone
    if (-not $vm) { return }
    $action = Read-Choice -Prompt 'Action' -Default 'Start' -Options @('Start', 'Deallocate', 'Restart', 'Stop')
    Invoke-RepoScript -Path $script:Scripts.ServerPower -Params @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $vm.ResourceGroupName; Name = @($vm.Name); Action = $action }
}

function Invoke-NewServer {
    Write-Title 'New server'
    $p = @{ SubscriptionId = $script:SubscriptionId }
    $p.ResourceGroupName = Read-Value 'Resource group (must exist)' -Key 'serverRg' -Required
    $location = try { (Get-AzResourceGroup -Name $p.ResourceGroupName -ErrorAction Stop).Location } catch { Write-Host "  Resource group not found: $($_.Exception.Message)" -ForegroundColor Red; return }
    $p.Name = Read-Value 'VM name (15 characters or fewer)' -Required
    $p.SubnetId = Read-Value 'Subnet resource ID' -Key 'subnet' -Required
    $images = @(try { Get-ServerImageCatalog -Location $location } catch { @() })
    $p.ImageKey = if ($images.Count -gt 0) { Read-Choice -Prompt 'Image' -Key 'serverImage' -Default 'windowsserver:2025-datacenter-azure-edition' -Options $images -AllowOther } else { Read-Value 'Image key' -Default 'windowsserver:2025-datacenter-azure-edition' }
    $p.VMSize = Select-VmSize -Location $location -Default 'Standard_D2s_v5' -Key 'serverSize'
    $p.LocalAdminCredential = Read-Cred -Message 'Local administrator for the server' -Key 'serverAdmin'
    $p += Read-ServerRole
    if ($p.Role -in 'ADForest', 'SQL') {
        $what = if ($p.Role -eq 'SQL') { 'SQL data, logs and backups' } else { 'the AD database and SYSVOL' }
        if (Read-YesNo "  Add a data disk for ${what}? (recommended; No = on the OS disk)" $true) {
            $p.DataDiskGB = [int](Read-Value 'Role disk GB' -Default $(if ($p.Role -eq 'SQL') { '256' } else { '32' }))
        } else { $p.DataDiskGB = 0 }
    }
    if (Read-YesNo '  Add a general-purpose data disk?' $false) { $p.GeneralDataDiskGB = [int](Read-Value 'General disk GB' -Default '64') }
    if (Read-YesNo '  Add a public IP? (no NSG rule is opened)' $false) { $p.PublicIp = $true }
    if (Read-YesNo '  Pin the private IP?' ($p.Role -eq 'ADForest')) { $p.StaticPrivateIp = $true }
    if (Read-YesNo '  Azure Hybrid Benefit (only with Software Assurance)?' $false) { $p.HybridBenefit = $true }
    Invoke-RepoScript -Path $script:Scripts.ServerNew -Params $p
}

function Invoke-InstallServerRole {
    Write-Title 'Install a role on an existing VM'
    $p = @{ SubscriptionId = $script:SubscriptionId }
    $p.ResourceGroupName = Read-Value 'Resource group' -Key 'serverRg' -Required
    $p.Name = Read-Value 'VM name' -Required
    $p += Read-ServerRole -Default 'IIS'
    if ($p.Role -eq 'None') { return }
    $drive = Read-Value 'Data drive letter (blank = keep files on the OS disk)' -Default $(if ($p.Role -eq 'IIS') { '' } else { 'F' })
    $p.DataDrive = $drive
    Invoke-RepoScript -Path $script:Scripts.ServerRole -Params $p
}

function Show-NetworkInventory {
    Write-Title 'Virtual networks'
    $vnets = @(Get-NetVirtualNetworkInfo)
    if ($vnets.Count -eq 0) { Write-Host '  No virtual networks.'; return }
    $vnets | Format-Table Name, ResourceGroupName, Location, AddressSpace, DnsServers, Subnets -AutoSize | Out-Host
    $v = Select-Item -Title 'Show subnets of which network?' -Items $vnets -Label { "$($_.Name)  ($($_.ResourceGroupName))" } -AllowNone
    if ($v) { Get-NetSubnetInfo -VirtualNetworkId $v.Id | Format-Table Name, AddressPrefix, Nsg, RouteTable, Delegation, Nics -AutoSize | Out-Host }
}

function Invoke-NewVNet {
    Write-Title 'Create a virtual network'
    $p = @{ SubscriptionId = $script:SubscriptionId }
    $p.ResourceGroupName = Read-Value 'Resource group (must exist)' -Key 'netRg' -Required
    $p.Name = Read-Value 'VNet name' -Required
    $p.AddressPrefix = @((Read-Value 'Address space (CIDR, comma separated for several)' -Default '10.20.0.0/16') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $p.SubnetName = Read-Value 'First subnet name' -Default 'default'
    $p.SubnetPrefix = Read-Value 'First subnet prefix' -Default '10.20.1.0/24'
    $dns = Read-Value 'DNS servers (comma separated; blank = Azure default)'
    if ($dns) { $p.DnsServer = @($dns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    Invoke-RepoScript -Path $script:Scripts.NetVNetNew -Params $p
}

function Select-VNet {
    $vnets = @(Get-NetVirtualNetworkInfo)
    if ($vnets.Count -eq 0) { Write-Host '  No virtual networks.' -ForegroundColor Yellow; return $null }
    Select-Item -Title 'Which network?' -Items $vnets -Label { "$($_.Name)  ($($_.ResourceGroupName), $($_.AddressSpace))" } -AllowNone
}

function Invoke-NewSubnet {
    Write-Title 'Add a subnet'
    $v = Select-VNet
    if (-not $v) { return }
    $p = @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $v.ResourceGroupName; VirtualNetworkName = $v.Name }
    $p.Name = Read-Value 'Subnet name' -Required
    $p.AddressPrefix = Read-Value "Address prefix inside $($v.AddressSpace)" -Required
    $nsgs = @(Get-NetSecurityGroupInfo)
    if ($nsgs.Count -gt 0) {
        $n = Select-Item -Title 'Attach a network security group? (Enter for none)' -Items $nsgs -Label { "$($_.Name)  ($($_.ResourceGroupName))" } -AllowNone
        if ($n) { $p.NetworkSecurityGroupId = $n.Id }
    }
    Invoke-RepoScript -Path $script:Scripts.NetSubnetNew -Params $p
}

function Invoke-EditNetwork {
    Write-Title 'Edit a network'
    $v = Select-VNet
    if (-not $v) { return }
    $what = Read-Choice -Prompt 'Edit' -Default 'dns' -Options @(
        [pscustomobject]@{ Value = 'dns';    Label = "DNS servers (now: $($v.DnsServers))" }
        [pscustomobject]@{ Value = 'space';  Label = "Add address space (now: $($v.AddressSpace))" }
        [pscustomobject]@{ Value = 'subnet'; Label = 'A subnet: prefix, attach or detach an NSG' }
    )
    switch ($what) {
        'dns' {
            $p = @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $v.ResourceGroupName; Name = $v.Name }
            $dns = Read-Value 'DNS servers (comma separated; blank = Azure default)'
            if ($dns) { $p.DnsServer = @($dns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $p.AzureDefaultDns = $true }
            Invoke-RepoScript -Path $script:Scripts.NetVNetSet -Params $p
        }
        'space' {
            $p = @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $v.ResourceGroupName; Name = $v.Name; AddAddressPrefix = @(Read-Value 'CIDR to add' -Required) }
            Invoke-RepoScript -Path $script:Scripts.NetVNetSet -Params $p
        }
        'subnet' {
            $subnets = @(Get-NetSubnetInfo -VirtualNetworkId $v.Id)
            $s = Select-Item -Title 'Which subnet?' -Items $subnets -Label { "$($_.Name)  $($_.AddressPrefix)  nsg=$($_.Nsg)" } -AllowNone
            if (-not $s) { return }
            $p = @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $v.ResourceGroupName; VirtualNetworkName = $v.Name; Name = $s.Name }
            $prefix = Read-Value 'New address prefix (blank = keep)' -Default $s.AddressPrefix
            if ($prefix -ne $s.AddressPrefix) { $p.AddressPrefix = $prefix }
            $nsgChoice = Read-Choice -Prompt 'Network security group' -Default 'keep' -Options @(
                [pscustomobject]@{ Value = 'keep';   Label = "Keep as is ($(if ($s.Nsg) { $s.Nsg } else { 'none' }))" }
                [pscustomobject]@{ Value = 'attach'; Label = 'Attach one' }
                [pscustomobject]@{ Value = 'detach'; Label = 'Detach the current one' })
            if ($nsgChoice -eq 'attach') {
                $n = Select-Item -Title 'Which NSG?' -Items @(Get-NetSecurityGroupInfo) -Label { "$($_.Name)  ($($_.ResourceGroupName))" } -AllowNone
                if ($n) { $p.NetworkSecurityGroupId = $n.Id }
            } elseif ($nsgChoice -eq 'detach') { $p.DetachNetworkSecurityGroup = $true }
            Invoke-RepoScript -Path $script:Scripts.NetSubnetSet -Params $p
        }
    }
}

function Invoke-RdpGrant {
    Write-Title 'Generate RDP'
    $p = @{ SubscriptionId = $script:SubscriptionId }
    $p.ResourceGroupName = Read-Value 'Resource group of the VM' -Key 'serverRg' -Required
    $p.Name = Read-Value 'VM name' -Required
    $p.Minutes = [int](Read-Choice -Prompt 'How long' -Default '60' -Options @(
        [pscustomobject]@{ Value = '30'; Label = '30 minutes' }; [pscustomobject]@{ Value = '60'; Label = '1 hour' }
        [pscustomobject]@{ Value = '120'; Label = '2 hours' };   [pscustomobject]@{ Value = '240'; Label = '4 hours' }
        [pscustomobject]@{ Value = '480'; Label = '8 hours' }))
    if (Read-YesNo '  Entra-joined machine (sign in with an Entra account)?' $false) { $p.EntraAuth = $true }
    if (Read-YesNo '  Launch mstsc when ready?' $true) { $p.Launch = $true }
    Invoke-RepoScript -Path $script:Scripts.RdpGrant -Params $p
    Write-Host '  Remember to close it (option 19) when you are done; the console has no timer.' -ForegroundColor Yellow
}

function Invoke-RdpRevoke {
    Write-Title 'Close RDP'
    $p = @{ SubscriptionId = $script:SubscriptionId }
    $p.ResourceGroupName = Read-Value 'Resource group' -Key 'serverRg' -Required
    $n = Read-Value 'VM name (blank = close every expired grant in the group)'
    if ($n) { $p.Name = $n }
    Invoke-RepoScript -Path $script:Scripts.RdpRevoke -Params $p
}

function Invoke-Autoscale {
    Write-Title "Autoscale for $($script:Pool.Name)"
    $plans = @(Get-AvdScalingPlan -ResourceGroupName $script:Pool.ResourceGroupName -HostPoolName $script:Pool.Name)
    if ($plans.Count -gt 0) {
        $plans | Format-Table Name, EnabledForPool, AttachedToPool, TimeZone, Schedules -AutoSize -Wrap | Out-Host
        $pick = Read-Choice -Prompt 'What now' -Default 'edit' -Options @(
            [pscustomobject]@{ Value = 'edit';   Label = 'Edit the schedule of one of these (Enter keeps each current value)' }
            [pscustomobject]@{ Value = 'toggle'; Label = 'Enable or disable one of these for this pool' }
            [pscustomobject]@{ Value = 'new';    Label = 'Create another plan' }
            [pscustomobject]@{ Value = 'back';   Label = 'Back to the menu' }
        )
        if ($pick -eq 'back') { return }
        if ($pick -eq 'edit') {
            $plan = Select-Item -Title 'Which plan?' -Items $plans -Label { "$($_.Name)  $($_.TimeZone)" } -AllowNone
            if (-not $plan) { return }
            $w = $plan.Weekday
            if (-not $w) { Write-Host '  That plan has no weekday schedule to edit.' -ForegroundColor Yellow; return }
            $p = @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $script:Pool.ResourceGroupName; Name = $plan.Name }
            $p.TimeZone      = Read-Value 'Time zone' -Default $plan.TimeZone
            $p.RampUpStart   = Read-Value 'Ramp-up starts' -Default $w.RampUpStart
            $p.PeakStart     = Read-Value 'Peak starts' -Default $w.PeakStart
            $p.RampDownStart = Read-Value 'Ramp-down starts' -Default $w.RampDownStart
            $p.OffPeakStart  = Read-Value 'Off-peak starts' -Default $w.OffPeakStart
            $p.RampUpMinimumHostsPct   = [int](Read-Value 'Minimum hosts on during ramp-up (%)' -Default "$($w.RampUpMinimumHostsPct)")
            $p.RampDownMinimumHostsPct = [int](Read-Value 'Minimum hosts on during ramp-down and off-peak (%)' -Default "$($w.RampDownMinimumHostsPct)")
            $p.RampDownWaitTimeMinutes = [int](Read-Value 'Warning minutes before a host is stopped' -Default "$($w.RampDownWaitTimeMinutes)")
            $p.RampDownMessage     = Read-Value 'Warning shown to users' -Default $w.RampDownMessage
            $p.RampDownForceLogoff = Read-YesNo '  Sign out users who ignore the warning?' ([bool]$w.RampDownForceLogoff)
            $p.WeekendOffPeak      = Read-YesNo '  Weekends off-peak all day?' ([bool]$plan.HasWeekend)
            Invoke-RepoScript -Path $script:Scripts.ScalingEdit -Params $p
            return
        }
        if ($pick -eq 'toggle') {
            $plan = Select-Item -Title 'Which plan?' -Items $plans -Label { "$($_.Name)  enabled=$($_.EnabledForPool)" } -AllowNone
            if (-not $plan) { return }
            $enabled = Read-YesNo "  Enable '$($plan.Name)' for $($script:Pool.Name)? (No = disable)" (-not $plan.EnabledForPool)
            if (-not (Read-YesNo "  $(if ($enabled) { 'Enable' } else { 'Disable' }) it now?" $true)) { return }
            $poolId = (Get-AzWvdHostPool -ResourceGroupName $script:Pool.ResourceGroupName -Name $script:Pool.Name).Id
            $null = Set-AvdScalingPlanEnabled -ResourceGroupName $script:Pool.ResourceGroupName -Name $plan.Name -HostPoolId $poolId -Enabled $enabled -Verbose
            Write-Host '  Done.' -ForegroundColor Green
            return
        }
    } else {
        Write-Host '  No scaling plan in this resource group yet.'
    }
    if ($script:Pool.Type -ne 'Pooled' -and $script:Pool.Type -ne '?') { Write-Host "  $($script:Pool.Name) is $($script:Pool.Type); this builds Pooled schedules only." -ForegroundColor Yellow; return }
    $p = @{ SubscriptionId = $script:SubscriptionId; ResourceGroupName = $script:Pool.ResourceGroupName; HostPoolName = $script:Pool.Name }
    $p.Name          = Read-Value 'Plan name' -Default "sp-$($script:Pool.Name)"
    $p.TimeZone      = Read-Value 'Time zone (Windows ID)' -Default (Get-TimeZone).Id
    $p.RampUpStart   = Read-Value 'Ramp-up starts (HH:mm, hosts power on ahead of users)' -Default '07:00'
    $p.PeakStart     = Read-Value 'Peak starts (full capacity)' -Default '09:00'
    $p.RampDownStart = Read-Value 'Ramp-down starts (consolidate, warn stragglers)' -Default '18:00'
    $p.OffPeakStart  = Read-Value 'Off-peak starts (minimum hosts)' -Default '20:00'
    $p.RampDownWaitTimeMinutes = [int](Read-Value 'Warning minutes before a host is stopped' -Default '30')
    if (Read-YesNo '  Sign out users who ignore the warning?' $false) { $p.RampDownForceLogoff = $true }
    if (Read-YesNo '  Weekends off-peak all day?' $true) { $p.WeekendOffPeak = $true }
    $p.RoleScope = Read-Choice -Prompt 'Grant the AVD service its power role at' -Default 'Subscription' -Options @('Subscription', 'ResourceGroup')
    Invoke-RepoScript -Path $script:Scripts.ScalingPlan -Params $p
}

function Invoke-NewHostPool {
    Write-Title 'Create host pool'
    $env = if ($script:Remembered.ContainsKey('env')) { $script:Remembered['env'] } else { 'lab' }
    $p = @{
        SubscriptionId    = $script:SubscriptionId
        ResourceGroupName = Read-Value 'Resource group' -Key 'rg' -Default "rg-avd-$env" -Required
        Location          = Read-Value 'Location (AVD metadata region)' -Key 'location' -Default 'westus3' -Required
        HostPoolName      = Read-Value 'Host pool name' -Default "hp-$env" -Required
        WorkspaceName     = Read-Value 'Workspace name' -Default "ws-$env" -Required
        HostPoolType      = Read-Value 'Type (Pooled/Personal)' -Default 'Pooled'
    }
    if ($p.HostPoolType -eq 'Pooled') {
        $p.LoadBalancerType = Read-Value 'Load balancer (BreadthFirst/DepthFirst)' -Default 'BreadthFirst'
        $p.MaxSessionLimit  = [int](Read-Value 'Max sessions per host' -Default '10')
    }
    $group = Select-EntraGroup -Purpose 'desktop access'
    if ($group) { $p.UserGroupObjectId = $group }
    if (Read-YesNo 'Will hosts be Entra ID joined (not AD)?' $true) { $p.EntraJoined = $true }
    if (Read-YesNo 'Enable Start VM On Connect?' $false) { $p.StartVMOnConnect = $true }

    Invoke-RepoScript -Path $script:Scripts.NewHostPool -Params $p
    if (Read-YesNo 'Switch the console to this pool?' $true) {
        $script:Pool = @{ Name = $p.HostPoolName; ResourceGroupName = $p.ResourceGroupName; Type = $p.HostPoolType }
    }
}

function Read-ImageAndJoin {
    <#
    .SYNOPSIS
        The questions shared by "add host" and "reimage host".
    #>
    $p = @{
        ImageSource = Read-Value 'Image source (Marketplace/Gallery)' -Key 'imageSource' -Default 'Marketplace'
    }
    if ($p.ImageSource -eq 'Gallery') {
        $p.GalleryResourceGroupName   = Read-Value 'Gallery resource group' -Key 'galleryRg' -Required
        $p.GalleryName                = Read-Value 'Gallery name' -Key 'gallery' -Required
        $p.GalleryImageDefinitionName = Read-Value 'Image definition' -Key 'imageDef' -Required
        $p.GalleryImageVersion        = Read-Value 'Image version' -Key 'imageVer' -Default 'latest'
    } else {
        $loc = try { (Get-AzResourceGroup -Name $script:Pool.ResourceGroupName -ErrorAction Stop).Location } catch { $null }
        $p.ImageSku = Read-Choice -Prompt 'Marketplace image' -Key 'imageSku' -Default 'win11-25h2-avd-m365' -Options (Get-ImageSkuOptionList -Location $loc) -AllowOther
    }
    $p.JoinType             = Read-Value 'Join type (EntraId/ActiveDirectory)' -Key 'joinType' -Default 'EntraId'
    $p.LocalAdminCredential = Read-Cred -Message 'Local administrator for the VM' -Key 'localAdmin'
    if ($p.JoinType -eq 'EntraId') {
        $group = Select-EntraGroup -Purpose 'VM sign-in'
        if ($group) { $p.UserGroupObjectId = $group }
    }
    if ($p.JoinType -eq 'ActiveDirectory') {
        $p.DomainName           = Read-Value 'Domain FQDN' -Key 'domain' -Required
        $p.DomainJoinCredential = Read-Cred -Message "Account that can join $($p.DomainName)" -Key 'domainJoin'
        $ou = Read-Value 'OU path (blank for default)' -Key 'ou'
        if ($ou) { $p.OUPath = $ou }
    }
    $share = Read-Value 'FSLogix profile share UNC (blank to skip)' -Key 'fslogix'
    if ($share) { $p.FsLogixProfileShare = $share }
    return $p
}

function Test-HostNameAvailable {
    <#
    .SYNOPSIS
        Warn if a VM or an Entra device record already carries a planned host name.
        Returns $true if a stale device record (record, no VM) was found, so the
        caller can ask whether the build may delete it.
    #>
    param([string[]]$Names, [string]$ResourceGroupName)
    $stale = $false
    foreach ($n in $Names) {
        if ($ResourceGroupName -and (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $n -ErrorAction SilentlyContinue)) {
            Write-Host "  $n already exists as a VM in $ResourceGroupName and will be skipped." -ForegroundColor Yellow
            continue
        }
        try {
            $found = @(Find-AvdEntraDevice -Name $n)
            if ($found.Count -gt 0) {
                Write-Host "  Entra ID still has a device record named $n from a deleted VM. The join fails until it is gone." -ForegroundColor Yellow
                $stale = $true
            }
        } catch {
            Write-Host "  (could not check Entra for a device named ${n}: $($_.Exception.Message))" -ForegroundColor DarkGray
        }
    }
    return $stale
}

function Invoke-NewSessionHost {
    Write-Title "Add session host to $($script:Pool.Name)"
    $token = Get-AvdRegistrationToken -ResourceGroupName $script:Pool.ResourceGroupName -HostPoolName $script:Pool.Name
    # Default name: avd-<pool label>-NN where NN is one more than the hosts already in the pool.
    $existingCount = @(Get-AvdSessionHostInfo -ResourceGroupName $script:Pool.ResourceGroupName -HostPoolName $script:Pool.Name).Count
    $poolLabel = ($script:Pool.Name -replace '^hp-', '')
    $suggestedVm = '{0}{1:d2}' -f "avd-$poolLabel-", ($existingCount + 1)
    $p = @{
        SubscriptionId            = $script:SubscriptionId
        HostPoolName              = $script:Pool.Name
        HostPoolResourceGroupName = $script:Pool.ResourceGroupName
        RegistrationToken         = $token.Token
        ResourceGroupName         = Read-Value 'VM resource group' -Key 'vmRg' -Default $script:Pool.ResourceGroupName
        VMName                    = Read-Value 'VM name (max 15 chars)' -Default $suggestedVm -Required
    }
    if (Test-HostNameAvailable -Names $p.VMName -ResourceGroupName $p.ResourceGroupName) {
        if (Read-YesNo '  Let the build delete that stale Entra device record? (No = delete it yourself in Entra admin center > Devices first)' $false) { $p.RemoveStaleEntraDevice = $true }
    }
    $p += @{
        VMSize                    = Select-VmSize -Location $(try { (Get-AzResourceGroup -Name $script:Pool.ResourceGroupName -ErrorAction Stop).Location } catch { $null }) -Default 'Standard_D4s_v5' -Key 'vmSize'
        SubnetId                  = Read-Value 'Subnet resource ID' -Key 'subnet' -Required
        SecurityType              = Read-Choice -Prompt 'Security type' -Key 'secType' -Default 'TrustedLaunch' -Options @('TrustedLaunch', 'Standard')
    }
    $p += Read-ImageAndJoin
    Invoke-RepoScript -Path $script:Scripts.NewHost -Params $p
}

function Invoke-Drain {
    param([ValidateSet('DrainOn', 'DrainOff', 'ListSessions', 'Message', 'LogOff')][string]$Action)
    Write-Title "$Action"
    $h = Select-SessionHost
    if (-not $h) { return }
    $p = @{
        SubscriptionId    = $script:SubscriptionId
        ResourceGroupName = $script:Pool.ResourceGroupName
        HostPoolName      = $script:Pool.Name
        SessionHostName   = $h.Name
        Action            = $Action
    }
    if ($Action -eq 'Message') {
        $p.MessageTitle = Read-Value 'Title' -Default 'Maintenance'
        $p.MessageBody  = Read-Value 'Message' -Required
    }
    if ($Action -eq 'LogOff') { $p.Force = $true }
    Invoke-RepoScript -Path $script:Scripts.Drain -Params $p -Destructive:($Action -eq 'LogOff')
}

function Invoke-Reimage {
    Write-Title "Reimage a host in $($script:Pool.Name)"
    $h = Select-SessionHost -Title 'Which host to replace'
    if (-not $h) { return }
    $p = @{
        SubscriptionId      = $script:SubscriptionId
        ResourceGroupName   = $script:Pool.ResourceGroupName
        HostPoolName        = $script:Pool.Name
        SessionHostName     = $h.Name
        DrainTimeoutMinutes = [int](Read-Value 'Minutes to give users before log-off' -Default '30')
        Force               = (Read-YesNo 'Log off anyone still connected after that?' $true)
        Confirm             = $false
    }
    $p += Read-ImageAndJoin
    Invoke-RepoScript -Path $script:Scripts.Reimage -Params $p -Destructive
}

function Invoke-RepairHost {
    <#
    .SYNOPSIS
        Finish or repair an existing VM: agent, FSLogix, login role, wait for Available.
    #>
    Write-Title "Repair a session host in $($script:Pool.Name)"
    $vms = @(Get-AzVM -ResourceGroupName $script:Pool.ResourceGroupName | Sort-Object Name)
    $vm = Select-Item -Title "VMs in $($script:Pool.ResourceGroupName)" -Items $vms -Label { "$($_.Name)  ($($_.HardwareProfile.VmSize))" }
    if (-not $vm) { return }
    $p = @{
        SubscriptionId            = $script:SubscriptionId
        ResourceGroupName         = $script:Pool.ResourceGroupName
        HostPoolName              = $script:Pool.Name
        HostPoolResourceGroupName = $script:Pool.ResourceGroupName
        VMName                    = $vm.Name
        JoinType                  = Read-Value 'Join type (EntraId/ActiveDirectory)' -Key 'joinType' -Default 'EntraId'
    }
    if ($p.JoinType -eq 'EntraId') {
        if (Read-YesNo 'Redo the Entra join first (host shows DomainJoinedCheck failed, or dsregcmd says AzureAdJoined NO)?' $false) { $p.RejoinEntra = $true }
        $group = Select-EntraGroup -Purpose 'VM sign-in'
        if ($group) { $p.UserGroupObjectId = $group }
    }
    $share = Read-Value 'FSLogix profile share UNC (blank to leave FSLogix alone)' -Key 'fslogix'
    if ($share) { $p.FsLogixProfileShare = $share }
    if (Read-YesNo 'Force a new registration token?' $false) { $p.ForceNewToken = $true }
    Invoke-RepoScript -Path $script:Scripts.Repair -Params $p
}

function Invoke-Teardown {
    <#
    .SYNOPSIS
        Delete a resource group and the Entra leftovers (device records, storage app).
    #>
    Write-Title 'Tear down an environment'
    $groups = @(Get-AzResourceGroup | Sort-Object ResourceGroupName)
    $rg = Select-Item -Title 'Resource groups in this subscription' -Items $groups -Label {
        $tag = if ($_.Tags -and $_.Tags.ContainsKey('workload')) { " [$($_.Tags['workload'])]" } else { '' }
        "$($_.ResourceGroupName)  ($($_.Location))$tag"
    } -AllowNone
    if (-not $rg) { return }
    $count = @(Get-AzResource -ResourceGroupName $rg.ResourceGroupName).Count
    Write-Host "  $($rg.ResourceGroupName) holds $count resource(s). ALL of them will be deleted, plus the Entra device records" -ForegroundColor Yellow
    Write-Host '  for its VMs and the Entra app for its storage accounts. This cannot be undone.' -ForegroundColor Yellow
    $typed = Read-Host "  Type the resource group name to confirm"
    if ($typed -ne $rg.ResourceGroupName) { Write-Host '  Name did not match. Nothing deleted.'; return }
    $p = @{
        SubscriptionId    = $script:SubscriptionId
        ResourceGroupName = $rg.ResourceGroupName
        Force             = $true
    }
    if (Read-YesNo '  Also delete the AVD user group? (usually no; keep it for the rebuild)' $false) {
        $g = Select-EntraGroup -Purpose 'deletion'
        if ($g) { $p.RemoveUserGroupObjectId = $g }
    }
    Invoke-RepoScript -Path $script:Scripts.Teardown -Params $p -Destructive
    if ($script:Pool -and $script:Pool.ResourceGroupName -eq $rg.ResourceGroupName) { $script:Pool = $null }
}

function Invoke-Backup {
    Write-Title 'Enable backup'
    $p = @{
        SubscriptionId            = $script:SubscriptionId
        ResourceGroupName         = Read-Value 'Vault resource group' -Key 'vaultRg' -Default $script:Pool.ResourceGroupName
        VaultName                 = Read-Value 'Vault name' -Key 'vault' -Default "rsv-avd-$($script:Pool.Name -replace '^hp-', '')" -Required
        Location                  = Read-Value 'Vault location (same region as the VMs)' -Key 'location' -Default 'westus3' -Required
        StorageRedundancy         = Read-Value 'Redundancy (LocallyRedundant/ZoneRedundant/GeoRedundant)' -Default 'LocallyRedundant'
        RetentionDays             = [int](Read-Value 'Retention days' -Default '30')
        HostPoolName              = $script:Pool.Name
        HostPoolResourceGroupName = $script:Pool.ResourceGroupName
    }
    $sa = Read-Value 'FSLogix storage account (blank to skip share backup)' -Key 'profileSa'
    if ($sa) {
        $p.ProfileStorageAccountName = $sa
        $p.ProfileShareName          = Read-Value 'Share name' -Key 'profileShare' -Required
    }
    Invoke-RepoScript -Path $script:Scripts.Backup -Params $p
}
#endregion

#region 6b. New environment wizard -------------------------------------------
#   WHAT   Ask every question for a new environment up front, in the order the
#          build happens, show the plan, then hand it to New-AvdEnvironment.ps1.
#   WHY    Answering questions one step at a time means discovering at step 6
#          that you needed a storage account name at step 3. All questions first,
#          then one confirmation, then an uninterrupted build. The orchestrator
#          owns the order and the hand-offs; this function only collects answers.
#   GOTCHA Identity is asked first because it decides which later questions
#          exist. Only Entra ID is wired up today; Active Directory says so and
#          returns to the menu, where the individual scripts still take an AD join.
function Invoke-NewEnvironmentWizard {
    Write-Title 'Build a new AVD environment'
    Write-Host '  Every question has a recommended default where one makes sense. Press Enter to take it.'
    Write-Host '  Nothing is created until you confirm the plan at the end.'

    # --- Identity -----------------------------------------------------------
    $identity = Select-Item -Title 'Identity service for the session hosts' -Items @(
        [pscustomobject]@{ Key = 'EntraId';         Label = 'Microsoft Entra ID joined (no domain controllers, FSLogix via Entra Kerberos)' }
        [pscustomobject]@{ Key = 'ActiveDirectory'; Label = 'Active Directory joined (not in the wizard yet; use the menu scripts)' }
    ) -Label { $_.Label } -DefaultIndex 1
    if (-not $identity -or $identity.Key -ne 'EntraId') {
        Write-Host '  The wizard only builds Entra ID environments today. Returning to the menu.' -ForegroundColor Yellow
        return
    }

    # --- Scope --------------------------------------------------------------
    $env      = Read-Value 'Environment label (2-10 lowercase letters/digits, used in names)' -Key 'env' -Default 'lab' -Required
    $location = Read-Value 'Azure region (must be an AVD metadata region)' -Key 'location' -Default 'westus3' -Required
    $rg       = Read-Value 'Resource group (one group for the whole environment)' -Key 'rg' -Default "rg-avd-$env" -Required

    # --- Network ------------------------------------------------------------
    $addressPrefix = Read-Value 'VNet address space' -Default '10.10.0.0/16'
    $subnetPrefix  = Read-Value 'Session host subnet' -Default '10.10.1.0/24'

    # --- Profile storage ----------------------------------------------------
    $deployStorage = Read-YesNo 'Deploy FSLogix profile storage (Azure Files with Entra Kerberos)?' $true
    $storageName = $storageSku = $shareName = $null
    $ntfs = $pause = $false
    if ($deployStorage) {
        $storageName = Read-Value 'Storage account name (globally unique, 3-24 lowercase letters/digits)' -Key 'profileSa' -Default "stavd${env}prof01" -Required
        $storageSku  = Read-Choice -Prompt 'Storage SKU' -Default 'Standard_LRS' -Options @(
            [pscustomobject]@{ Value = 'Standard_LRS'; Label = 'Cheap. Fine for a lab.' }
            [pscustomobject]@{ Value = 'Premium_LRS';  Label = 'Fast file storage. Use for real profiles.' }
            [pscustomobject]@{ Value = 'Premium_ZRS';  Label = 'Premium, zone redundant.' }
        )
        $shareName   = Read-Value 'Share name' -Key 'profileShare' -Default 'profiles'
        $ntfsVia     = Read-Choice -Prompt 'FSLogix NTFS permissions on the share' -Default 'SessionHost' -Options @(
            [pscustomobject]@{ Value = 'SessionHost'; Label = 'From the first session host after it is built. Works regardless of your ISP.' }
            [pscustomobject]@{ Value = 'Local';       Label = 'From this machine now. Needs outbound TCP 445, which most ISPs block.' }
            [pscustomobject]@{ Value = 'Skip';        Label = 'Not now. Run menu option B later.' }
        )
        $ntfs        = ($ntfsVia -ne 'Skip')
        $pause       = Read-YesNo 'Pause after storage so you can grant admin consent before hosts are built?' $true
    }

    # --- Gallery ------------------------------------------------------------
    $deployGallery = Read-YesNo 'Also create a Compute Gallery for custom images later?' $false
    $galleryName = $imageDef = $null
    if ($deployGallery) {
        $galleryName = Read-Value 'Gallery name (no hyphens)' -Key 'gallery' -Default "gal_avd_$env"
        $imageDef    = Read-Value 'Image definition name' -Key 'imageDef' -Default 'win11-avd-m365'
    }

    # --- Users --------------------------------------------------------------
    Write-Host '  Users need an Entra security group. It gets the desktop and VM sign-in rights.'
    $group = Select-EntraGroup -Purpose 'AVD users'

    # --- Host pool ----------------------------------------------------------
    $poolName  = Read-Value 'Host pool name' -Default "hp-$env"
    $wsName    = Read-Value 'Workspace name' -Default "ws-$env"
    $poolType  = Read-Choice -Prompt 'Pool type' -Default 'Pooled' -Options @(
        [pscustomobject]@{ Value = 'Pooled';   Label = 'Shared hosts, FSLogix profiles. Most deployments.' }
        [pscustomobject]@{ Value = 'Personal'; Label = 'One VM per user, profile stays on the VM.' }
    )
    $lb = 'BreadthFirst'; $maxSessions = 10
    if ($poolType -eq 'Pooled') {
        $lb          = Read-Choice -Prompt 'Load balancing' -Default 'BreadthFirst' -Options @(
            [pscustomobject]@{ Value = 'BreadthFirst'; Label = 'Spread users across hosts. Best performance.' }
            [pscustomobject]@{ Value = 'DepthFirst';   Label = 'Fill one host before the next. Best for autoscale cost.' }
        )
        $maxSessions = [int](Read-Value 'Max sessions per host' -Default '10')
    }
    $startOnConnect = Read-YesNo 'Enable Start VM On Connect?' $false

    # --- Session hosts ------------------------------------------------------
    $hostCount = [int](Read-Value 'How many session hosts to build now (0 for none)' -Default '1')
    $prefix = "avd-$env-"; $vmSize = 'Standard_D4s_v5'; $sku = 'win11-25h2-avd-m365'; $secType = 'TrustedLaunch'; $cred = $null
    if ($hostCount -gt 0) {
        $prefix  = Read-Value 'Host name prefix (hosts become <prefix>01, <prefix>02...; prefix + 2 digits must be 15 chars or less)' -Default $prefix
        $removeStale = $false
        if (Test-HostNameAvailable -Names @(1..$hostCount | ForEach-Object { '{0}{1:d2}' -f $prefix, $_ }) -ResourceGroupName $rg) {
            $removeStale = Read-YesNo '  Let the build delete those stale Entra device records? (No = delete them yourself in Entra admin center > Devices first)' $false
        }
        $vmSize  = Select-VmSize -Location $location -Default $vmSize -Key 'vmSize'
        $sku     = Read-Choice -Prompt 'Marketplace image' -Key 'imageSku' -Default $sku -Options (Get-ImageSkuOptionList -Location $location) -AllowOther
        $secType = Read-Choice -Prompt 'Security type' -Key 'secType' -Default $secType -Options @(
            [pscustomobject]@{ Value = 'TrustedLaunch'; Label = 'Secure Boot + vTPM. Default; marketplace images support it.' }
            [pscustomobject]@{ Value = 'Standard';      Label = 'Only if the image is not Gen2 / Trusted Launch capable.' }
        )
        $cred    = Read-Cred -Message 'Local administrator for the session hosts' -Key 'localAdmin'
    }

    # --- Backup -------------------------------------------------------------
    $backup = Read-YesNo 'Create a Recovery Services vault and protect the profile share now?' $false
    $vaultName = if ($backup) { Read-Value 'Vault name' -Key 'vault' -Default "rsv-avd-$env" } else { $null }

    # --- Plan ---------------------------------------------------------------
    $p = @{
        SubscriptionId       = $script:SubscriptionId
        Environment          = $env
        Location             = $location
        ResourceGroupName    = $rg
        IdentityType         = 'EntraId'
        AddressPrefix        = $addressPrefix
        SubnetPrefix         = $subnetPrefix
        DeployProfileStorage = $deployStorage
        DeployGallery        = $deployGallery
        HostPoolName         = $poolName
        WorkspaceName        = $wsName
        HostPoolType         = $poolType
        LoadBalancerType     = $lb
        MaxSessionLimit      = $maxSessions
        StartVMOnConnect     = $startOnConnect
        SessionHostCount     = $hostCount
        SessionHostPrefix    = $prefix
        VMSize               = $vmSize
        ImageSku             = $sku
        SecurityType         = $secType
        EnableBackup         = $backup
        Interactive          = $true
    }
    if ($hostCount -gt 0 -and $removeStale) { $p.RemoveStaleEntraDevice = $true }
    if ($deployStorage) {
        $p.StorageAccountName   = $storageName
        $p.StorageSkuName       = $storageSku
        $p.ProfileShareName     = $shareName
        $p.SetNtfsPermissions   = $ntfs
        if ($ntfs) { $p.NtfsVia = $ntfsVia }
        $p.PauseForAdminConsent = $pause
    }
    if ($deployGallery) { $p.GalleryName = $galleryName; $p.ImageDefinitionName = $imageDef }
    if ($group)         { $p.UserGroupObjectId = $group }
    if ($cred)          { $p.LocalAdminCredential = $cred }
    if ($vaultName)     { $p.VaultName = $vaultName }

    $permsOk = Show-PermissionReport -ResourceGroupName $rg -IncludeBackup $backup
    if (-not $permsOk -and -not (Read-YesNo '  Continue anyway?' $false)) { return }

    Write-Title 'Plan'
    Write-Host "  1. Register resource providers"
    Write-Host "  2. Resource group $rg in $location"
    Write-Host ("  3. VNet $addressPrefix with subnet $subnetPrefix" + $(if ($deployStorage) { ", storage $storageName/$shareName ($storageSku, Entra Kerberos)" }) + $(if ($deployGallery) { ", gallery $galleryName" }))
    if ($deployStorage) { Write-Host "  4. Share access: NTFS $(if ($ntfs) { "via $ntfsVia" } else { 'skipped' }), admin consent $(if ($pause) { 'pause' } else { 'reminder only' })" }
    Write-Host ("  5. Host pool $poolName ($poolType), workspace $wsName, Entra joined" + $(if ($group) { ", users: $group" } else { ', NO user group' }))
    Write-Host ("  6. $hostCount session host(s): ${prefix}01.. $vmSize, $sku, Entra joined" + $(if ($deployStorage) { ', FSLogix on the share' }))
    if ($backup) { Write-Host "  7. Backup vault $vaultName" }

    Invoke-RepoScript -Path $script:Scripts.Environment -Params $p

    # Land the menu on what was just built.
    $script:Pool = @{ Name = $poolName; ResourceGroupName = $rg; Type = $poolType }
    $script:Remembered['rg'] = $rg
    if ($deployStorage) { $script:Remembered['fslogix'] = "\\$storageName.file.core.windows.net\$shareName" }
}
#endregion

#region 7. Menu loop ----------------------------------------------------------
#   WHAT   Print the menu, read a choice, dispatch, repeat until Q.
#   WHY    A plain loop with a switch is all a console needs. No framework.
#   GOTCHA 'break' inside a switch only leaves the switch, not the loop, which is
#          why $running is a flag instead.
$running = $true
if (-not $script:Pool) {
    $mode = Select-Item -Title 'What are you doing today?' -Items @(
        [pscustomobject]@{ Key = 'new';      Label = 'Build a new environment (asks everything up front, then builds)' }
        [pscustomobject]@{ Key = 'existing'; Label = 'Work with an existing environment' }
    ) -Label { $_.Label } -DefaultIndex 1
    if ($mode -and $mode.Key -eq 'new') { Invoke-NewEnvironmentWizard } else { Select-HostPool }
}
while ($running) {
    $poolLabel = if ($script:Pool) { "$($script:Pool.Name) ($($script:Pool.ResourceGroupName))" } else { 'none selected' }
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host "  Subscription: $((Get-AzContext).Subscription.Name)"
    Write-Host "  Host pool:    $poolLabel"
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '   N. Build a new environment (wizard)'
    Write-Host '   0. Prepare subscription (register resource providers)'
    Write-Host '   C. Check what this account is allowed to do'
    Write-Host '   A. Deploy lab infrastructure: network, profile storage, optional gallery (Bicep)'
    Write-Host '   B. Configure profile share access (Entra Kerberos, NTFS)'
    Write-Host '   1. Show host pool status'
    Write-Host '   2. Create a host pool'
    Write-Host '   3. Add a session host'
    Write-Host '   4. Drain a host (block new sessions)'
    Write-Host '   5. Un-drain a host'
    Write-Host '   6. List sessions on a host'
    Write-Host '   7. Message users on a host'
    Write-Host '   8. Log off users on a host'
    Write-Host '   9. Reimage a host'
    Write-Host '   R. Repair a host (re-run agent, FSLogix, login role on an existing VM)'
    Write-Host '  10. Enable backup'
    Write-Host '  11. Autoscale: create or toggle a scaling plan'
    Write-Host '  12. Host power: start, deallocate, restart one host'
    Write-Host '  13. Rolling restart (drain, message, wait, restart, undrain, one host at a time)'
    Write-Host '  14. Agent update maintenance window'
    Write-Host '  15. Servers: inventory and power (any VM, not just session hosts)'
    Write-Host '  16. New server (optionally IIS, AD DS forest, or SQL Server)'
    Write-Host '  17. Install a role on an existing server'
    Write-Host '  18. Generate RDP: open 3389 from your IP for a while, write and launch the .rdp (any VM)'
    Write-Host '  19. Close RDP on a VM, or close every expired grant in a resource group'
    Write-Host '  20. Networks: list VNets and subnets'
    Write-Host '  21. Create a VNet with its first subnet'
    Write-Host '  22. Add a subnet (optionally with an NSG)'
    Write-Host '  23. Edit a VNet (DNS servers, add address space) or a subnet (prefix, NSG)'
    Write-Host '   X. Tear down an environment (delete resource group + Entra leftovers)'
    Write-Host '   P. Pick a different host pool'
    Write-Host '   S. Pick a different subscription'
    Write-Host '   Q. Quit'
    $choice = (Read-Host '  Choose').Trim().ToUpperInvariant()

    $needsPool = $choice -in @('1', '3', '4', '5', '6', '7', '8', '9', 'R', '10', '11', '12', '13', '14')
    if ($needsPool -and -not $script:Pool) {
        Write-Host '  Pick a host pool first (P), or create one (2).' -ForegroundColor Yellow
        continue
    }

    try {
        switch ($choice) {
            'N'  { Invoke-NewEnvironmentWizard }
            '0'  { Invoke-PrepareSubscription }
            'C'  { $null = Show-PermissionReport -ResourceGroupName $(if ($script:Pool) { $script:Pool.ResourceGroupName } else { '' }) }
            'A'  { Invoke-DeployLab }
            'B'  { Invoke-ShareAccess }
            '1'  { Show-PoolStatus }
            '2'  { Invoke-NewHostPool }
            '3'  { Invoke-NewSessionHost }
            '4'  { Invoke-Drain -Action DrainOn }
            '5'  { Invoke-Drain -Action DrainOff }
            '6'  { Invoke-Drain -Action ListSessions }
            '7'  { Invoke-Drain -Action Message }
            '8'  { Invoke-Drain -Action LogOff }
            '9'  { Invoke-Reimage }
            'R'  { Invoke-RepairHost }
            '10' { Invoke-Backup }
            '11' { Invoke-Autoscale }
            '12' { Invoke-HostPower }
            '13' { Invoke-RollingRestart }
            '14' { Invoke-AgentWindow }
            '15' { Invoke-ServerInventory }
            '16' { Invoke-NewServer }
            '17' { Invoke-InstallServerRole }
            '18' { Invoke-RdpGrant }
            '19' { Invoke-RdpRevoke }
            '20' { Show-NetworkInventory }
            '21' { Invoke-NewVNet }
            '22' { Invoke-NewSubnet }
            '23' { Invoke-EditNetwork }
            'X'  { Invoke-Teardown }
            'P'  { Select-HostPool }
            'S'  { Select-Subscription; Select-HostPool }
            'Q'  { $running = $false }
            default { Write-Host '  Not an option.' -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}
#endregion
