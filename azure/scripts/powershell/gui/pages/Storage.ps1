<#
    Azure Files and backup pages for Start-AvdGui.ps1: Azure Files list and add,
    Backup and restore (servers and file shares), Backup policies. Dot-sourced by
    the main script; uses its helpers and $Gui.
    Restores only ever write somewhere new or skip existing files; shortening a
    policy's retention (which prunes recovery points) asks first. Nothing here
    stops protection or deletes a share, account, vault or recovery point.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-*/Set-*/Update-* here build or refresh WPF controls. Changes go through the repo scripts, which support -WhatIf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Handlers and OnDone callbacks have fixed signatures.')]
param()

# --- Azure Files: list --------------------------------------------------------
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

function New-FilesListPage {
    $page = @{ Key = 'NavFilesList'; Accounts = @() }
    $root = New-PageRoot -Title 'Azure Files' -Lead 'Storage accounts that hold file shares. Select one to see its shares with usage against quota. A share near its quota is the early warning for full FSLogix profiles.'
    $page.Grid = New-DataGrid -Height 220
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.Busy) { Invoke-FilesShareList -Page $pg } }
    $null = $root.Children.Add((New-TableCard -Title 'Storage accounts' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-FilesAccountList -Page $pg }),
        (New-ToolButton -Text 'Add share' -OnClick { Show-Page 'NavFilesAdd' }))))
    $page.ShareGrid = New-DataGrid -Height 220
    $page.ShareGrid.SelectionMode = 'Single'
    $actions = @(
        @{ Text = 'Change quota...'; Context = $page; Handler = { param($pg) Invoke-FilesQuota -Page $pg } }
        @{ Text = 'Copy UNC path'; Context = $page; Handler = { param($pg) $s = Get-GridSelection $pg.ShareGrid; if ($s.Count -eq 1) { [System.Windows.Clipboard]::SetText($s[0].Unc); Write-GuiLog "Copied $($s[0].Unc)" 'ok' } } }
        @{ Text = 'Back up or restore'; Handler = { Show-Page 'NavFilesBackup' } }
    )
    Set-GridRowMenu -Grid $page.ShareGrid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Shares of the selected account' -Grid $page.ShareGrid -Tools @((New-MenuButton -Items $actions))))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Invoke-FilesAccountList -Page $pg } }
    $page.Root = $root
    return $page
}

function Invoke-FilesAccountList {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List storage accounts' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        Get-FilesAccountInfo
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Accounts = @($result)
        $pg.ShareGrid.ItemsSource = $null
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Accounts -Columns @('Name', 'ResourceGroupName', 'Location', 'Kind', 'Sku', 'IdentityAuth', 'PublicAccess', 'MinTls')).DefaultView
    }
}

function Invoke-FilesShareList {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { return }
    Start-Work -Name "Shares of $($sel[0].Name)" -Argument @{ Rg = $sel[0].ResourceGroupName; Name = $sel[0].Name } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-FilesShareInfo -ResourceGroupName $Job.Rg -StorageAccountName $Job.Name
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.ShareGrid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('Name', 'QuotaGiB', 'UsedGiB', 'PercentUsed', 'Tier', 'Protocol', 'Unc', 'Account', 'ResourceGroupName')).DefaultView
    }
}

function Invoke-FilesQuota {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.ShareGrid
    if ($sel.Count -ne 1) { Show-Message 'Select one share.' 'Quota' 'Warning'; return }
    $v = Show-InputDialog -Title "Quota for $($sel[0].Name)" -Text "Now $($sel[0].QuotaGiB) GiB, $($sel[0].UsedGiB) GiB used. New quota in GiB (premium bills for the quota):" -Default $sel[0].QuotaGiB -OkText 'Set quota'
    if (-not $v) { return }
    if ($v -notmatch '^\d+$') { Show-Message 'Whole GiB, please.' 'Quota' 'Warning'; return }
    Invoke-RepoScript -Name "Quota $($sel[0].Name) = $v GiB" -Path $Gui.Scripts.FilesQuota -Context $Page -Params @{
        SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $sel[0].ResourceGroupName; StorageAccountName = $sel[0].Account; ShareName = $sel[0].Name; QuotaGiB = [int]$v
    } -OnDone { param($result, $failure, $pg) if (-not $failure) { Invoke-FilesShareList -Page $pg } }
}

# --- Azure Files: add ---------------------------------------------------------
function New-FilesAddPage {
    $page = @{ Key = 'NavFilesAdd'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'Add a file share' -Lead 'A share in an existing storage account, or a new account with secure defaults (HTTPS only, TLS 1.2, no anonymous access). For FSLogix permissions use Profile storage afterwards.'
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Share' -Fields @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Type = 'combo'; Required = $true }
        @{ Name = 'StorageAccountName'; Label = 'Storage account (pick, or type a new name)'; Type = 'combo'; Editable = $true; Required = $true; Help = '3 to 24 lower-case letters and digits for a new one.' }
        @{ Name = 'ShareName'; Label = 'Share name'; Required = $true; Default = 'profiles'; Help = 'Lower-case letters, digits and single hyphens.' }
        @{ Name = 'QuotaGiB'; Label = 'Quota (GiB)'; Type = 'int'; Default = 100 }
        @{ Name = 'Performance'; Label = 'New account: performance'; Type = 'combo'; Default = 'Premium'; Options = @(@{ Value = 'Premium'; Label = 'Premium SSD (FSLogix profiles)' }, @{ Value = 'Standard'; Label = 'Standard (general files)' }) }
        @{ Name = 'Redundancy'; Label = 'New account: redundancy'; Type = 'combo'; Default = 'LRS'; Options = @('LRS', 'ZRS') }
        @{ Name = 'AccessTier'; Label = 'Standard shares: access tier'; Type = 'combo'; Default = ''; Options = @(@{ Value = ''; Label = 'Default' }, 'TransactionOptimized', 'Hot', 'Cool') }
    )))
    $Gui.RgCombos.Add($form.Controls['ResourceGroupName'])
    Add-ControlHandler -Control $form.Controls['ResourceGroupName'] -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.SuppressEvents -and -not $Gui.State.Busy) { Start-FilesAddAccountLoad -Page $pg } }
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create share' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-FilesAdd -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-FilesAdd -Page $c.Page -DryRun:$c.DryRun }))))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Update-ResourceGroupList -Context $pg -OnDone { param($p) Start-FilesAddAccountLoad -Page $p } } }
    $page.Root = $root
    return $page
}

function Start-FilesAddAccountLoad {
    param([hashtable]$Page)
    $rg = Get-FormValue $Page.Form 'ResourceGroupName'
    if (-not $rg) { return }
    Start-Work -Name "Storage accounts in $rg" -Argument @{ Rg = $rg } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-FilesAccountInfo -ResourceGroupName $Job.Rg
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $c = $pg.Form.Controls['StorageAccountName']
        Add-ComboOption -Combo $c -Options @(@($result) | ForEach-Object { @{ Value = $_.Name; Label = "$($_.Name)  ($($_.Sku))" } }) -Default (Get-ComboValue $c)
    }
}

function Invoke-FilesAdd {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form)) { return }
    $f = $Page.Form
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId }
    Add-FormParameter -Params $p -Form $f -Names @('ResourceGroupName', 'StorageAccountName', 'ShareName', 'QuotaGiB', 'Performance', 'Redundancy', 'AccessTier')
    Invoke-RepoScript -Name "Create share $($p.ShareName)" -Path $Gui.Scripts.FilesShareNew -Params $p -DryRun:$DryRun
}

# --- Backup and restore (servers or file shares) --------------------------------
function New-ServerBackupPage { return (Build-BackupRestorePage -Kind 'VM') }
function New-FilesBackupPage  { return (Build-BackupRestorePage -Kind 'FileShare') }

function Build-BackupRestorePage {
    param([ValidateSet('VM', 'FileShare')] [string]$Kind)
    $isVm = $Kind -eq 'VM'
    $page = @{ Key = $(if ($isVm) { 'NavServerBackup' } else { 'NavFilesBackup' }); Kind = $Kind; Form = New-Form; Items = @(); Vaults = @() }
    $form = $page.Form
    $noun = if ($isVm) { 'VMs' } else { 'file shares' }
    $root = New-PageRoot -Title $(if ($isVm) { 'Server backup and restore' } else { 'File share backup and restore' }) -Lead "Protected $noun in every Recovery Services vault, their last backup, and recovery points. Restores write somewhere new (or, for a share, skip files that still exist); nothing is ever overwritten. Stopping protection is done in the portal."

    $page.Grid = New-DataGrid -Height 220
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.Busy) { Invoke-BackupPointList -Page $pg } }
    $actions = @(
        @{ Text = 'Back up now';            Context = $page; Handler = { param($pg) Invoke-BackupNow -Page $pg }; ToolTip = 'Kept 30 days' }
        @{ Text = 'Show recovery points';   Context = $page; Handler = { param($pg) Invoke-BackupPointList -Page $pg } }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title "Protected $noun" -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-BackupPageLoad -Page $pg }),
        (New-MenuButton -Items $actions)) -Note 'Health and last status come from Azure Backup. "never" means the first backup has not run yet: use Back up now.'))
    $page.PointGrid = New-DataGrid -Height 160
    $page.PointGrid.SelectionMode = 'Single'
    $null = $root.Children.Add((New-TableCard -Title 'Recovery points of the selected item (last 30 days)' -Grid $page.PointGrid -Note 'Select one, then fill the Restore card below.'))

    if ($isVm) {
        $restore = New-FormSection -Form $form -Title 'Restore' -Subtitle 'As a new VM (name it, pick its subnet), or as disks only (leave the name empty). The original VM is not touched.' -Fields @(
            @{ Name = 'RestoreRg'; Label = 'Target resource group'; Type = 'combo'; Required = $true }
            @{ Name = 'RestoreVmName'; Label = 'New VM name (empty = disks only)' }
            @{ Name = 'RestoreSubnet'; Label = 'Subnet for the new VM'; Type = 'combo'; Span = 2 }
            @{ Name = 'RestoreStaging'; Label = 'Staging storage account (Standard, vault region)'; Type = 'combo'; Required = $true; Span = 2; Help = 'Holds the VM configuration and a template. Not a premium account.' }
        )
        $Gui.RgCombos.Add($form.Controls['RestoreRg'])
    } else {
        $restore = New-FormSection -Form $form -Title 'Restore' -Subtitle 'To another share and a new folder, or back into the same share skipping every file that still exists. Nothing is overwritten.' -Fields @(
            @{ Name = 'RestoreMode'; Label = 'Where'; Type = 'combo'; Default = 'AlternateLocation'; Options = @(@{ Value = 'AlternateLocation'; Label = 'Another share, new folder' }, @{ Value = 'OriginalLocation'; Label = 'Same share, only missing files' }) }
            @{ Name = 'RestorePath'; Label = 'File or folder in the share (empty = everything)'; Help = 'Relative to the share root, for example Profiles/user1.' }
            @{ Name = 'RestoreType'; Label = 'That path is a'; Type = 'combo'; Default = 'Directory'; Options = @('Directory', 'File') }
            @{ Name = 'RestoreAccount'; Label = 'Target storage account (another share)'; Type = 'combo' }
            @{ Name = 'RestoreShare'; Label = 'Target share (another share)' }
            @{ Name = 'RestoreFolder'; Label = 'Target folder (another share)'; Default = "restore-$((Get-Date).ToString('yyyyMMdd-HHmm'))" }
        )
    }
    $null = $restore.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Restore' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-BackupRestore -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-BackupRestore -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($restore)

    $protectFields = @(
        @{ Name = 'Vault'; Label = 'Vault (pick, or type a new name)'; Type = 'combo'; Editable = $true; Required = $true; Help = 'Must be in the same region as what it protects.' }
        @{ Name = 'VaultRg'; Label = 'Vault resource group'; Type = 'combo'; Required = $true }
        @{ Name = 'Policy'; Label = 'Policy (created if missing: daily, 30 days, 02:00 UTC)'; Type = 'combo'; Editable = $true; Default = $(if ($isVm) { 'vm-daily' } else { 'files-daily' }); Options = @($(if ($isVm) { 'vm-daily' } else { 'files-daily' })) }
    )
    if ($isVm) { $protectFields += @{ Name = 'ProtectVm'; Label = 'VM'; Type = 'combo'; Required = $true; Span = 2 } }
    else {
        $protectFields += @{ Name = 'ProtectAccount'; Label = 'Storage account'; Type = 'combo'; Required = $true }
        $protectFields += @{ Name = 'ProtectShare'; Label = 'Share'; Required = $true }
    }
    $protect = New-FormSection -Form $form -Title "Protect a $(if ($isVm) { 'VM' } else { 'file share' })" -Subtitle 'Creates the vault and the policy if they do not exist. The first backup runs at the policy time; Back up now takes one at once.' -Fields $protectFields
    $Gui.RgCombos.Add($form.Controls['VaultRg'])
    $null = $protect.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Protect' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-BackupProtect -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-BackupProtect -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($protect)

    $page.JobGrid = New-DataGrid -Height 180
    $null = $root.Children.Add((New-TableCard -Title 'Backup and restore jobs, last 48 hours' -Grid $page.JobGrid))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Update-ResourceGroupList -Context $pg -OnDone { param($p) Start-BackupPageLoad -Page $p } } }
    $page.Root = $root
    return $page
}

function Start-BackupPageLoad {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name "Load $($Page.Kind) backups" -Argument @{ Kind = $Page.Kind } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $r = @{ Items = @(Get-BackupItemInfo -Kind $Job.Kind); Vaults = @(Get-BackupVaultInfo); Jobs = @(Get-BackupJobInfo -Hours 48)
                Accounts = @(Get-FilesAccountInfo); Vms = @(); Subnets = @() }
        if ($Job.Kind -eq 'VM') {
            $r.Vms = @(Get-AzVM | Sort-Object ResourceGroupName, Name | ForEach-Object { [pscustomobject]@{ Value = "$($_.ResourceGroupName)|$($_.Name)"; Label = "$($_.Name)  ($($_.ResourceGroupName), $($_.Location))" } })
            $r.Subnets = @(Get-AzVirtualNetwork | Sort-Object ResourceGroupName, Name | ForEach-Object {
                $v = $_; foreach ($s in $v.Subnets) { [pscustomobject]@{ Value = "$($v.ResourceGroupName)|$($v.Name)|$($s.Name)"; Label = "$($v.ResourceGroupName)/$($v.Name)/$($s.Name)  ($($v.Location))" } } })
        }
        [pscustomobject]$r
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $f = $pg.Form
        $pg.Items = @($r.Items); $pg.Vaults = @($r.Vaults)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Items -Columns @('Name', 'Source', 'LastBackup', 'LastStatus', 'Health', 'State', 'Policy', 'Vault')).DefaultView
        $pg.PointGrid.ItemsSource = $null
        $pg.JobGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Jobs) -Columns @('Item', 'Operation', 'Status', 'Started', 'Duration', 'Vault')).DefaultView
        Add-ComboOption -Combo $f.Controls['Vault'] -Options @($pg.Vaults | ForEach-Object { @{ Value = $_.Name; Label = "$($_.Name)  ($($_.ResourceGroupName), $($_.Location))" } }) -Default (Get-ComboValue $f.Controls['Vault'])
        $accounts = @($r.Accounts | ForEach-Object { @{ Value = "$($_.ResourceGroupName)|$($_.Name)"; Label = "$($_.Name)  ($($_.Sku), $($_.Location))" } })
        if ($pg.Kind -eq 'VM') {
            Add-ComboOption -Combo $f.Controls['ProtectVm'] -Options @($r.Vms | ForEach-Object { @{ Value = $_.Value; Label = $_.Label } }) -Default (Get-ComboValue $f.Controls['ProtectVm'])
            Add-ComboOption -Combo $f.Controls['RestoreSubnet'] -Options (@(@{ Value = ''; Label = 'None (disks only)' }) + @($r.Subnets | ForEach-Object { @{ Value = $_.Value; Label = $_.Label } })) -Default (Get-ComboValue $f.Controls['RestoreSubnet'])
            Add-ComboOption -Combo $f.Controls['RestoreStaging'] -Options @($r.Accounts | Where-Object { $_.Sku -like 'Standard*' } | ForEach-Object { @{ Value = "$($_.ResourceGroupName)|$($_.Name)"; Label = "$($_.Name)  ($($_.Sku), $($_.Location))" } }) -Default (Get-ComboValue $f.Controls['RestoreStaging'])
        } else {
            Add-ComboOption -Combo $f.Controls['ProtectAccount'] -Options $accounts -Default (Get-ComboValue $f.Controls['ProtectAccount'])
            Add-ComboOption -Combo $f.Controls['RestoreAccount'] -Options (@(@{ Value = ''; Label = '(same share, only missing files)' }) + $accounts) -Default (Get-ComboValue $f.Controls['RestoreAccount'])
        }
        $unhealthy = @($pg.Items | Where-Object { $_.LastStatus -and $_.LastStatus -notin 'Completed', 'Succeeded' })
        if ($unhealthy.Count -gt 0) { Write-GuiLog "$($unhealthy.Count) item(s) whose last backup did not complete: $(@($unhealthy | ForEach-Object Name) -join ', ')." 'warn' }
    }
}

function Get-BackupSelectedItem {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { return $null }
    return ($Page.Items | Where-Object { $_.Name -eq $sel[0].Name -and $_.Vault -eq $sel[0].Vault } | Select-Object -First 1)
}

function Invoke-BackupPointList {
    param([hashtable]$Page)
    $it = Get-BackupSelectedItem -Page $Page
    if (-not $it) { return }
    Start-Work -Name "Recovery points of $($it.Name)" -Argument @{ VaultId = $it.VaultId; Kind = $it.Kind; ItemName = $it.ItemName } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-BackupRecoveryPointInfo -VaultId $Job.VaultId -Kind $Job.Kind -ItemName $Job.ItemName
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.PointGrid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('Time', 'Type', 'Tier', 'Id')).DefaultView
        if (@($result).Count -eq 0) { Write-GuiLog 'No recovery points in the last 30 days.' 'warn' }
    }
}

function Invoke-BackupNow {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $it = Get-BackupSelectedItem -Page $Page
    if (-not $it) { Show-Message 'Select one protected item.' 'Back up now' 'Warning'; return }
    Invoke-RepoScript -Name "Back up $($it.Name) now" -Path $Gui.Scripts.BackupNow -Context $Page -Params @{
        SubscriptionId = $Gui.State.SubscriptionId; VaultId = $it.VaultId; Kind = $it.Kind; ItemName = @($it.ItemName)
    } -OnDone { param($result, $failure, $pg) if (-not $failure) { Start-BackupPageLoad -Page $pg } }
}

function Invoke-BackupRestore {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $it = Get-BackupSelectedItem -Page $Page
    if (-not $it) { Show-Message 'Select the protected item first.' 'Restore' 'Warning'; return }
    $rp = Get-GridSelection $Page.PointGrid
    if ($rp.Count -ne 1) { Show-Message 'Select one recovery point.' 'Restore' 'Warning'; return }
    $f = $Page.Form
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; VaultId = $it.VaultId; Kind = $it.Kind; ItemName = $it.ItemName; RecoveryPointId = $rp[0].Id }
    if ($it.Kind -eq 'VM') {
        if (-not (Test-FormRequired -Form $f -Only @('RestoreRg', 'RestoreStaging'))) { return }
        $st = (Get-FormValue $f 'RestoreStaging') -split '\|'
        $p.StagingStorageAccountResourceGroupName = $st[0]; $p.StagingStorageAccountName = $st[1]
        $p.TargetResourceGroupName = Get-FormValue $f 'RestoreRg'
        $vm = Get-FormValue $f 'RestoreVmName'
        if ($vm) {
            $sn = Get-FormValue $f 'RestoreSubnet'
            if (-not $sn) { Show-Message 'A new VM needs a subnet.' 'Restore' 'Warning'; return }
            $s = $sn -split '\|'
            $p.TargetVMName = $vm; $p.TargetVNetResourceGroupName = $s[0]; $p.TargetVNetName = $s[1]; $p.TargetSubnetName = $s[2]
        }
    } else {
        $p.Mode = Get-FormValue $f 'RestoreMode'
        $sp = Get-FormValue $f 'RestorePath'; if ($sp) { $p.SourcePath = $sp; $p.SourceType = Get-FormValue $f 'RestoreType' }
        if ($p.Mode -eq 'AlternateLocation') {
            $acct = Get-FormValue $f 'RestoreAccount'; $share = Get-FormValue $f 'RestoreShare'; $folder = Get-FormValue $f 'RestoreFolder'
            if (-not ($acct -and $share -and $folder)) { Show-Message 'Another share needs the account, the share and a folder.' 'Restore' 'Warning'; return }
            $p.TargetStorageAccountName = ($acct -split '\|')[1]; $p.TargetShareName = $share; $p.TargetFolder = $folder
        }
    }
    Invoke-RepoScript -Name "Restore $($it.Name) from $($rp[0].Time)" -Path $Gui.Scripts.BackupRestore -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-BackupPageLoad -Page $pg }
    }
}

function Invoke-BackupProtect {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $f = $Page.Form
    $need = @('Vault', 'VaultRg', 'Policy') + $(if ($Page.Kind -eq 'VM') { @('ProtectVm') } else { @('ProtectAccount', 'ProtectShare') })
    if (-not (Test-FormRequired -Form $f -Only $need)) { return }
    $vaultName = Get-FormValue $f 'Vault'
    $existing = $Page.Vaults | Where-Object Name -eq $vaultName | Select-Object -First 1
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; VaultName = $vaultName; VaultResourceGroupName = $(if ($existing) { $existing.ResourceGroupName } else { Get-FormValue $f 'VaultRg' }); PolicyName = (Get-FormValue $f 'Policy') }
    if ($Page.Kind -eq 'VM') {
        $vm = (Get-FormValue $f 'ProtectVm') -split '\|'
        $p.ResourceGroupName = $vm[0]; $p.VMName = @($vm[1])
    } else {
        $p.StorageAccountName = ((Get-FormValue $f 'ProtectAccount') -split '\|')[1]; $p.ShareName = Get-FormValue $f 'ProtectShare'
    }
    Invoke-RepoScript -Name 'Protect with Azure Backup' -Path $Gui.Scripts.BackupEnable -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-BackupPageLoad -Page $pg }
    }
}

# --- Backup policies ------------------------------------------------------------
function New-BackupPolicyPage {
    $page = @{ Key = 'NavBackupPolicy'; Form = New-Form; Policies = @(); Vaults = @() }
    $form = $page.Form
    $root = New-PageRoot -Title 'Backup policies' -Lead 'Daily VM and file share policies in every vault. Select one to change its time or retention. Keeping fewer days deletes the older recovery points, so that asks first.'
    $page.Grid = New-DataGrid -Height 240
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName SelectionChanged -Context $page -Handler { param($pg) Update-BackupPolicyForm -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Policies' -Grid $page.Grid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-BackupPolicyLoad -Page $pg }))))
    $edit = New-FormSection -Form $form -Title 'Selected policy' -Fields @(
        @{ Name = 'EditDays'; Label = 'Keep daily recovery points (days)'; Type = 'int' }
        @{ Name = 'EditTime'; Label = 'Run at (UTC, HH:00 or HH:30)' }
    )
    $null = $edit.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Save policy' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-BackupPolicySave -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-BackupPolicySave -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($edit)
    $create = New-FormSection -Form $form -Title 'Create a daily policy' -Fields @(
        @{ Name = 'NewVault'; Label = 'Vault'; Type = 'combo'; Required = $true }
        @{ Name = 'NewName'; Label = 'Name'; Required = $true }
        @{ Name = 'NewKind'; Label = 'For'; Type = 'combo'; Default = 'VM'; Options = @(@{ Value = 'VM'; Label = 'VMs (enhanced)' }, @{ Value = 'FileShare'; Label = 'File shares' }) }
        @{ Name = 'NewDays'; Label = 'Keep (days)'; Type = 'int'; Default = 30 }
        @{ Name = 'NewTime'; Label = 'Run at (UTC)'; Default = '02:00' }
    )
    $null = $create.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create policy' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-BackupPolicyCreate -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-BackupPolicyCreate -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($create)
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-BackupPolicyLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-BackupPolicyLoad {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List backup policies' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{ Policies = @(Get-BackupPolicyInfo); Vaults = @(Get-BackupVaultInfo) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Policies = @($r.Policies); $pg.Vaults = @($r.Vaults)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Policies -Columns @('Name', 'Workload', 'Subtype', 'RunsAt', 'KeepDays', 'Weekly', 'Monthly', 'Vault')).DefaultView
        Add-ComboOption -Combo $pg.Form.Controls['NewVault'] -Options @($pg.Vaults | ForEach-Object { @{ Value = $_.Id; Label = "$($_.Name)  ($($_.ResourceGroupName), $($_.Location))" } }) -Default (Get-ComboValue $pg.Form.Controls['NewVault'])
    }
}

function Get-BackupSelectedPolicy {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { return $null }
    return ($Page.Policies | Where-Object { $_.Name -eq $sel[0].Name -and $_.Vault -eq $sel[0].Vault } | Select-Object -First 1)
}

function Update-BackupPolicyForm {
    param([hashtable]$Page)
    $pol = Get-BackupSelectedPolicy -Page $Page
    if (-not $pol) { return }
    Set-FormValue -Form $Page.Form -Name 'EditDays' -Value $pol.KeepDays
    Set-FormValue -Form $Page.Form -Name 'EditTime' -Value ($pol.RunsAt -replace ' UTC$', '')
}

function Invoke-BackupPolicySave {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $pol = Get-BackupSelectedPolicy -Page $Page
    if (-not $pol) { Show-Message 'Select a policy.' 'Policy' 'Warning'; return }
    $days = Get-FormValue $Page.Form 'EditDays'; $time = Get-FormValue $Page.Form 'EditTime'
    if ($time -and $time -notmatch '^\d{2}:(00|30)$') { Show-Message 'Time must be HH:00 or HH:30.' 'Policy' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; VaultId = $pol.VaultId; Name = $pol.Name }
    if ($null -ne $days) { $p.RetentionDays = $days }
    if ($time) { $p.BackupTimeUtc = $time }
    if ($null -ne $days -and $days -lt [int]$pol.KeepDays) {
        if (-not (Confirm-Action "Keeping $days days instead of $($pol.KeepDays) makes Azure DELETE the recovery points older than $days days, for every item on $($pol.Name). Go on?" 'Shorter retention')) { return }
        $p.AllowShorterRetention = $true
    }
    Invoke-RepoScript -Name "Change policy $($pol.Name)" -Path $Gui.Scripts.BackupPolicy -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-BackupPolicyLoad -Page $pg }
    }
}

function Invoke-BackupPolicyCreate {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $f = $Page.Form
    if (-not (Test-FormRequired -Form $f -Only @('NewVault', 'NewName'))) { return }
    $time = Get-FormValue $f 'NewTime'
    if ($time -notmatch '^\d{2}:(00|30)$') { Show-Message 'Time must be HH:00 or HH:30.' 'Policy' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; VaultId = (Get-FormValue $f 'NewVault'); Name = (Get-FormValue $f 'NewName'); Kind = (Get-FormValue $f 'NewKind'); BackupTimeUtc = $time }
    $d = Get-FormValue $f 'NewDays'; if ($null -ne $d) { $p.RetentionDays = $d }
    Invoke-RepoScript -Name "Create policy $($p.Name)" -Path $Gui.Scripts.BackupPolicy -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-BackupPolicyLoad -Page $pg }
    }
}
