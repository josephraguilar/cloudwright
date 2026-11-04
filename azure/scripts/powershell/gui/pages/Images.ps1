<#
    Image pages for Start-AvdGui.ps1: Desktop images (Compute Gallery) and
    Windows 365 images. Dot-sourced by the main script; uses its helpers and $Gui.
    The cycle: create a definition, build a VM from a marketplace image, install
    apps (Generate RDP on the Servers page), capture. Sysprep is one-way, so the
    capture asks for the VM name typed out. Nothing here deletes a VM or a version.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-*/Set-*/Update-* here build or refresh WPF controls. Changes go through the repo scripts, which support -WhatIf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Handlers and OnDone callbacks have fixed signatures.')]
param()

# --- Desktop images -----------------------------------------------------------
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

function New-DesktopImagesPage {
    $page = @{ Key = 'NavImages'; Form = New-Form; Definitions = @() }
    $form = $page.Form
    $root = New-PageRoot -Title 'Desktop images' -Lead 'Compute Gallery image definitions and their versions. Build a VM from a marketplace image, install the apps, capture it as a version, then add session hosts from it. Sysprep is one-way: capture only a VM made for it.'

    $page.Grid = New-DataGrid -Height 220
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.Busy) { Invoke-ImageVersionList -Page $pg } }
    $actions = @(
        @{ Text = 'Show versions'; Context = $page; Handler = { param($pg) Invoke-ImageVersionList -Page $pg } }
        @{ Text = 'Capture into this definition'; Context = $page; Handler = { param($pg) Set-ImageCaptureDefinition -Page $pg }; ToolTip = 'Picks it in the Capture card below' }
        @{ Text = 'Add session hosts from it'; Context = $page; Handler = { param($pg) Invoke-ImageUseForHost -Page $pg }; ToolTip = 'Opens Add a host with this image chosen' }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Image definitions' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-ImagePageLoad -Page $pg }),
        (New-MenuButton -Items $actions))))
    $page.VersionGrid = New-DataGrid -Height 160
    $null = $root.Children.Add((New-TableCard -Title 'Versions of the selected definition' -Grid $page.VersionGrid -Note 'A capture shows as Creating for 15 to 60 minutes, then Succeeded. Versions excluded from latest are skipped by "latest" until you include them in the portal.'))

    $create = New-FormSection -Form $form -Title 'Create a gallery and image definition' -Subtitle 'An existing gallery or definition with the same name is reused. Trusted Launch must match the builder VM.' -Fields @(
        @{ Name = 'DefRg'; Label = 'Resource group'; Type = 'combo'; Required = $true }
        @{ Name = 'DefGallery'; Label = 'Gallery name (no hyphens)'; Type = 'combo'; Editable = $true; Required = $true }
        @{ Name = 'DefName'; Label = 'Definition name'; Required = $true; Help = 'For example win11-avd-apps.' }
        @{ Name = 'DefSecurity'; Label = 'Security type'; Type = 'combo'; Default = 'TrustedLaunch'; Options = @('TrustedLaunch', 'Standard') }
        @{ Name = 'DefDescription'; Label = 'Description'; Span = 2 }
    )
    $Gui.RgCombos.Add($form.Controls['DefRg'])
    $null = $create.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create definition' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-ImageDefinitionCreate -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-ImageDefinitionCreate -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($create)

    $builder = New-FormSection -Form $form -Title 'Image builder VM' -Subtitle 'No domain join, no AVD agent, no public IP. Tagged purpose=image-builder. Reach it with Generate RDP on the Servers page and install the apps.' -Fields @(
        @{ Name = 'BldRg'; Label = 'Resource group'; Type = 'combo'; Required = $true; Help = 'The image list follows its region.' }
        @{ Name = 'BldName'; Label = 'VM name (15 characters or fewer)'; Required = $true; Default = 'img-build-01' }
        @{ Name = 'BldImage'; Label = 'Start from'; Type = 'combo'; Required = $true; Span = 2; Help = 'Loads for the resource group''s region.' }
        @{ Name = 'BldSubnet'; Label = 'Subnet'; Type = 'combo'; Required = $true; Span = 2 }
        @{ Name = 'BldSize'; Label = 'Size'; Type = 'combo'; Editable = $true; Default = 'Standard_D4s_v5'; Options = @('Standard_D4s_v5', 'Standard_D8s_v5', 'Standard_D4as_v5', 'Standard_B4ms') }
        @{ Name = 'BldSecurity'; Label = 'Security type'; Type = 'combo'; Default = 'TrustedLaunch'; Options = @('TrustedLaunch', 'Standard') }
        @{ Name = 'AdminUser'; Label = 'Local administrator'; Default = 'imgadmin' }
        @{ Name = 'AdminPassword'; Label = 'Password'; Type = 'password' }
        @{ Name = 'AdminPasswordConfirm'; Label = 'Password again'; Type = 'password' }
    )
    $Gui.RgCombos.Add($form.Controls['BldRg'])
    Add-ControlHandler -Control $form.Controls['BldRg'] -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.SuppressEvents -and -not $Gui.State.Busy) { Start-ImageCatalogLoad -Page $pg } }
    $null = $builder.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create builder VM' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-ImageBuilderCreate -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-ImageBuilderCreate -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($builder)

    $capture = New-FormSection -Form $form -Title 'Capture' -Subtitle 'Sysprep (generalize, shut down), mark the VM Generalized, add a version. The VM cannot boot again afterwards; it stays, deallocated, until you delete it in the portal.' -Fields @(
        @{ Name = 'CapVm'; Label = 'Builder VM'; Type = 'combo'; Required = $true; Help = 'VMs tagged purpose=image-builder, unless "show every VM" is ticked.' }
        @{ Name = 'CapDefinition'; Label = 'Into definition'; Type = 'combo'; Required = $true }
        @{ Name = 'CapVersion'; Label = 'Version (three numbers)'; Help = 'Empty = from the date and time.' }
        @{ Name = 'CapReplicas'; Label = 'Also replicate to regions (comma separated, optional)' }
        @{ Name = 'CapManagedImage'; Label = 'Also make a managed image named (for Windows 365, optional)'; Span = 2 }
        @{ Name = 'CapExclude'; Label = 'Exclude from latest until tested'; Type = 'check'; Default = $true }
        @{ Name = 'CapAllVms'; Label = 'Show every VM, not just image builders'; Type = 'check'; Default = $false }
    )
    Add-ControlHandler -Control $form.Controls['CapAllVms'] -EventName Checked -Context $page -Handler { param($pg) if (-not $Gui.State.Busy) { Start-ImagePageLoad -Page $pg } }
    $null = $capture.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Sysprep and capture' -Style 'DangerButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-ImageCaptureRun -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-ImageCaptureRun -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($capture)

    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Update-ResourceGroupList -Context $pg -OnDone { param($p) Start-ImagePageLoad -Page $p } } }
    $page.Root = $root
    return $page
}

function Start-ImagePageLoad {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'Load images' -Argument @{ AllVms = [bool](Get-FormValue $Page.Form 'CapAllVms') } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $defs = @(Get-GalleryImageInfo)
        $galleries = @(Get-AzGallery | ForEach-Object { [pscustomobject]@{ Name = $_.Name; ResourceGroupName = $_.ResourceGroupName } })
        $vms = @(Get-AzVM | Where-Object { $Job.AllVms -or ($_.Tags -and $_.Tags.ContainsKey('purpose') -and $_.Tags['purpose'] -eq 'image-builder') } |
            Sort-Object ResourceGroupName, Name | ForEach-Object { [pscustomobject]@{ Value = "$($_.ResourceGroupName)|$($_.Name)"; Label = "$($_.Name)  ($($_.ResourceGroupName))" } })
        $subnets = @(Get-AzVirtualNetwork | Sort-Object ResourceGroupName, Name | ForEach-Object {
            $v = $_; foreach ($s in $v.Subnets) { [pscustomobject]@{ Value = $s.Id; Label = "$($v.ResourceGroupName)/$($v.Name)/$($s.Name)  $($s.AddressPrefix -join ',')  ($($v.Location))" } } })
        [pscustomobject]@{ Definitions = $defs; Galleries = $galleries; Vms = $vms; Subnets = $subnets; Version = (New-GalleryVersionNumber) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Definitions = @($r.Definitions)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Definitions -Columns @('Name', 'Gallery', 'ResourceGroupName', 'Latest', 'Versions', 'SecurityType', 'Generation', 'OsState', 'Location')).DefaultView
        $pg.VersionGrid.ItemsSource = $null
        $f = $pg.Form
        Add-ComboOption -Combo $f.Controls['DefGallery'] -Options @($r.Galleries | ForEach-Object { @{ Value = $_.Name; Label = "$($_.Name)  ($($_.ResourceGroupName))" } }) -Default (Get-ComboValue $f.Controls['DefGallery'])
        Add-ComboOption -Combo $f.Controls['CapVm'] -Options @($r.Vms | ForEach-Object { @{ Value = $_.Value; Label = $_.Label } }) -Default (Get-ComboValue $f.Controls['CapVm'])
        Add-ComboOption -Combo $f.Controls['CapDefinition'] -Options @($pg.Definitions | ForEach-Object { @{ Value = $_.Id; Label = "$($_.Gallery)/$($_.Name)  ($($_.SecurityType), latest $($_.Latest))" } }) -Default (Get-ComboValue $f.Controls['CapDefinition'])
        Add-ComboOption -Combo $f.Controls['BldSubnet'] -Options @($r.Subnets | ForEach-Object { @{ Value = $_.Value; Label = $_.Label } }) -Default (Get-ComboValue $f.Controls['BldSubnet'])
        $f.Controls['CapVersion'].Text = $r.Version
        Write-GuiLog "$($pg.Definitions.Count) image definition(s), $(@($r.Vms).Count) builder VM(s)." 'info'
        if (Get-ComboValue $f.Controls['BldRg']) { Start-ImageCatalogLoad -Page $pg }
    }
}

function Start-ImageCatalogLoad {
    param([hashtable]$Page)
    $rg = Get-ComboValue $Page.Form.Controls['BldRg']
    $loc = @($Gui.State.ResourceGroups | Where-Object Name -eq $rg | ForEach-Object Location) | Select-Object -First 1
    if (-not $loc) { return }
    Start-Work -Name "Marketplace images in $loc" -Argument @{ Location = $loc } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-GalleryMarketplaceCatalog -Location $Job.Location
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $c = $pg.Form.Controls['BldImage']
        Add-ComboOption -Combo $c -Options @(@($result) | ForEach-Object { @{ Value = $_.Value; Label = $_.Label } }) -Default (Get-ComboValue $c)
        if ($c.SelectedIndex -lt 0 -and $c.Items.Count -gt 0) { $c.SelectedIndex = 0 }
    }
}

function Get-ImageSelectedDefinition {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { return $null }
    return ($Page.Definitions | Where-Object { $_.Name -eq $sel[0].Name -and $_.Gallery -eq $sel[0].Gallery } | Select-Object -First 1)
}

function Invoke-ImageVersionList {
    param([hashtable]$Page)
    $d = Get-ImageSelectedDefinition -Page $Page
    if (-not $d) { return }
    Start-Work -Name "Versions of $($d.Name)" -Argument @{ Id = $d.Id } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-GalleryImageVersionInfo -DefinitionId $Job.Id
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.VersionGrid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('Version', 'State', 'Published', 'ExcludeFromLatest', 'Regions', 'SourceVm')).DefaultView
    }
}

function Set-ImageCaptureDefinition {
    param([hashtable]$Page)
    $d = Get-ImageSelectedDefinition -Page $Page
    if (-not $d) { Show-Message 'Select one definition.' 'Images' 'Warning'; return }
    Set-FormValue -Form $Page.Form -Name 'CapDefinition' -Value $d.Id
    $Page.Form.Controls['CapDefinition'].BringIntoView()
}

function Invoke-ImageUseForHost {
    param([hashtable]$Page)
    $d = Get-ImageSelectedDefinition -Page $Page
    if (-not $d) { Show-Message 'Select one definition.' 'Images' 'Warning'; return }
    if (-not $d.Latest) { Show-Message "$($d.Name) has no finished version yet." 'Images' 'Warning'; return }
    $Gui.State.PreferredImage = "gallery|$($d.ResourceGroupName)|$($d.Gallery)|$($d.Name)"
    Show-Page 'NavAddHost'
}

function Invoke-ImageDefinitionCreate {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form -Only @('DefRg', 'DefGallery', 'DefName'))) { return }
    $f = $Page.Form
    $p = @{
        SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-FormValue $f 'DefRg'); GalleryName = (Get-FormValue $f 'DefGallery')
        DefinitionName = (Get-FormValue $f 'DefName'); SecurityType = (Get-FormValue $f 'DefSecurity')
    }
    $d = Get-FormValue $f 'DefDescription'; if ($d) { $p.Description = $d }
    Invoke-RepoScript -Name "Create image definition $($p.DefinitionName)" -Path $Gui.Scripts.ImageDefinition -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-ImagePageLoad -Page $pg }
    }
}

function Invoke-ImageBuilderCreate {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $f = $Page.Form
    if (-not (Test-FormRequired -Form $f -Only @('BldRg', 'BldName', 'BldImage', 'BldSubnet'))) { return }
    $cred = Get-FormCredential $f
    if (-not $cred) { return }
    $p = @{
        SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-FormValue $f 'BldRg'); VMName = (Get-FormValue $f 'BldName')
        SubnetId = (Get-FormValue $f 'BldSubnet'); ImageKey = (Get-FormValue $f 'BldImage'); VMSize = (Get-FormValue $f 'BldSize')
        SecurityType = (Get-FormValue $f 'BldSecurity'); LocalAdminCredential = $cred
    }
    Invoke-RepoScript -Name "Create builder VM $($p.VMName)" -Path $Gui.Scripts.ImageBuilder -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-ImagePageLoad -Page $pg }
    }
}

function Invoke-ImageCaptureRun {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $f = $Page.Form
    if (-not (Test-FormRequired -Form $f -Only @('CapVm', 'CapDefinition'))) { return }
    $vm = (Get-FormValue $f 'CapVm') -split '\|'
    $p = @{
        SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $vm[0]; VMName = $vm[1]
        DefinitionId = (Get-FormValue $f 'CapDefinition'); Confirm = $false
    }
    $v = Get-FormValue $f 'CapVersion'; if ($v) { if ($v -notmatch '^\d+\.\d+\.\d+$') { Show-Message 'Version must be three whole numbers, like 1.0.0.' 'Version' 'Warning'; return }; $p.Version = $v }
    $reg = Split-CommaList (Get-FormValue $f 'CapReplicas'); if ($reg.Count -gt 0) { $p.ReplicaRegion = $reg }
    $mi = Get-FormValue $f 'CapManagedImage'; if ($mi) { $p.ManagedImageName = $mi }
    if (Get-FormValue $f 'CapExclude') { $p.ExcludeFromLatest = $true }
    if (Get-FormValue $f 'CapAllVms') { $p.AllowUntaggedVm = $true }
    if (-not $DryRun) {
        # Sysprep cannot be undone: the VM name is typed, not clicked.
        $typed = Show-InputDialog -Title 'Confirm sysprep' -Text "Sysprep makes $($vm[1]) unable to boot again. Type the VM name to go on." -OkText 'Sysprep and capture'
        if ($typed -ne $vm[1]) { if ($null -ne $typed) { Show-Message 'The name did not match. Nothing was done.' 'Capture' 'Warning' }; return }
    }
    Invoke-RepoScript -Name "Capture $($vm[1])" -Path $Gui.Scripts.ImageCapture -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-ImagePageLoad -Page $pg }
    }
}

# --- Windows 365 images -------------------------------------------------------
function New-W365ImagesPage {
    $page = @{ Key = 'NavW365Images' }
    $root = New-PageRoot -Title 'Windows 365 images' -Lead 'Windows 365 takes custom images from managed images (not gallery versions). Capture a builder VM on Desktop images with "Also make a managed image", then upload it here. Uses Microsoft Graph with Cloud PC rights; the first load opens a browser to consent.'
    $page.ManagedGrid = New-DataGrid -Height 180
    $page.ManagedGrid.SelectionMode = 'Single'
    $actions = @(@{ Text = 'Upload to Windows 365...'; Context = $page; Handler = { param($pg) Invoke-W365Upload -Page $pg } })
    Set-GridRowMenu -Grid $page.ManagedGrid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Managed images in the subscription' -Grid $page.ManagedGrid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-W365Load -Page $pg }),
        (New-MenuButton -Items $actions))))
    $page.ImageGrid = New-DataGrid -Height 180
    $null = $root.Children.Add((New-TableCard -Title 'Windows 365 custom images' -Grid $page.ImageGrid -Note 'An upload shows as pending for up to an hour, then ready or failed (with an error code).'))
    $page.PolicyGrid = New-DataGrid -Height 160
    $null = $root.Children.Add((New-TableCard -Title 'Provisioning policies' -Grid $page.PolicyGrid -Note 'Point a policy at a new image in Intune: Devices, Windows 365, Provisioning policies.'))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-W365Load -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-W365Load {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'Load Windows 365 images' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        $managed = @(Get-ManagedImageInfo)
        $w365 = @(); $policies = @()
        try { $w365 = @(Get-W365DeviceImageInfo); $policies = @(Get-W365ProvisioningPolicyInfo) }
        catch { Write-Warning "Windows 365: $($_.Exception.Message)" }
        [pscustomobject]@{ Managed = $managed; Images = $w365; Policies = $policies }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.ManagedGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Managed) -Columns @('Name', 'ResourceGroupName', 'Location', 'Generation', 'Source', 'Id')).DefaultView
        $pg.ImageGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Images) -Columns @('DisplayName', 'Version', 'Status', 'Os', 'Build', 'Modified', 'Source', 'Error')).DefaultView
        $pg.PolicyGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Policies) -Columns @('DisplayName', 'ImageType', 'Image', 'Join')).DefaultView
    }
}

function Invoke-W365Upload {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.ManagedGrid
    if ($sel.Count -ne 1) { Show-Message 'Select one managed image.' 'Windows 365' 'Warning'; return }
    $name = Show-InputDialog -Title 'Upload to Windows 365' -Text 'Display name in Intune.' -Default $sel[0].Name -OkText 'Next'
    if (-not $name) { return }
    $ver = Show-InputDialog -Title 'Upload to Windows 365' -Text 'Version: three whole numbers.' -Default '1.0.0' -OkText 'Upload'
    if (-not $ver) { return }
    if ($ver -notmatch '^\d+\.\d+\.\d+$') { Show-Message 'Version must be three whole numbers, like 1.0.0.' 'Version' 'Warning'; return }
    Invoke-RepoScript -Name "Upload $name to Windows 365" -Path $Gui.Scripts.W365Image -Params @{ SubscriptionId = $Gui.State.SubscriptionId; ManagedImageId = $sel[0].Id; DisplayName = $name; Version = $ver } -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-W365Load -Page $pg }
    }
}
