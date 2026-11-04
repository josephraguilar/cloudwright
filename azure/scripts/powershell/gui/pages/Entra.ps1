<#
    Entra pages for Start-AvdGui.ps1: Users, Groups, Add user, Add group, User
    actions. Dot-sourced by the main script (region 7); uses its helpers and $Gui.
    Reads go through EntraAdmin in the worker; every change runs a script under
    entra/ with the parameter preview first.
    Nothing here deletes a user or a group or removes a member: block sign-in is
    the off switch, and the Entra admin center is where deletes happen.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-*/Set-*/Update-* here build or refresh WPF controls. Changes go through the repo scripts, which support -WhatIf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Handlers and OnDone callbacks have fixed signatures.')]
param()

# --- Users --------------------------------------------------------------------
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

function New-EntraUsersPage {
    $page = @{ Key = 'NavEntraUsers'; Form = New-Form }
    $root = New-PageRoot -Title 'Users' -Lead 'Users in the directory of the signed-in account. Right-click a row, or select rows and open Manage. Users synced from Active Directory are changed in AD, not here.'
    $null = $root.Children.Add((New-SearchBar -Page $page -Help 'Start of a name, sign-in name or mail. Empty lists the first 500 users.' -OnSearch { param($pg) Invoke-EntraUsersRefresh -Page $pg }))
    $page.Grid = New-DataGrid -Height 340
    $actions = @(
        @{ Text = 'Block sign-in';   Context = @{ Page = $page; Action = 'BlockSignIn' };    Handler = { param($c) Invoke-EntraUserAction -Page $c.Page -Action $c.Action }; ToolTip = 'Stops new sign-ins and ends sessions within the hour. Allow sign-in undoes it.' }
        @{ Text = 'Allow sign-in';   Context = @{ Page = $page; Action = 'AllowSignIn' };    Handler = { param($c) Invoke-EntraUserAction -Page $c.Page -Action $c.Action } }
        @{ Text = 'Revoke sessions'; Context = @{ Page = $page; Action = 'RevokeSessions' }; Handler = { param($c) Invoke-EntraUserAction -Page $c.Page -Action $c.Action }; ToolTip = 'Apps ask the user to sign in again' }
        @{ Text = 'Reset password';  Context = @{ Page = $page; Action = 'ResetPassword' };  Handler = { param($c) Invoke-EntraUserAction -Page $c.Page -Action $c.Action }; ToolTip = 'Random password, shown once' }
        @{ Separator = $true }
        @{ Text = 'Add to group...';    Context = $page; Handler = { param($pg) Invoke-EntraUserToGroup -Page $pg } }
        @{ Text = 'Assign licence...';  Context = $page; Handler = { param($pg) Invoke-EntraUserLicense -Page $pg } }
        @{ Text = 'Show groups';        Context = $page; Handler = { param($pg) Invoke-EntraUserGroupList -Page $pg } }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Users' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-EntraUsersRefresh -Page $pg }),
        (New-ToolButton -Text 'Add user' -OnClick { Show-Page 'NavEntraAddUser' }),
        (New-MenuButton -Items $actions))))
    $page.GroupGrid = New-DataGrid -Height 180
    $null = $root.Children.Add((New-TableCard -Title 'Groups of the selected user' -Grid $page.GroupGrid -Note 'Fills when you pick Show groups on one user.'))
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Licence options' -Fields @(
        @{ Name = 'UsageLocation'; Label = 'Usage location for users who have none (two letters, optional)'; Help = 'A licence cannot be assigned without one. Example: US.' }
    )))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Invoke-EntraUsersRefresh -Page $pg } }
    $page.Root = $root
    return $page
}

function Invoke-EntraUsersRefresh {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List users' -Argument @{ Search = $Page.SearchBox.Text.Trim() } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $p = @{}; if ($Job.Search) { $p.Search = $Job.Search }
        Get-EntraUserInfo @p
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Loaded = $true
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('DisplayName', 'UserPrincipalName', 'SignIn', 'Source', 'Licenses', 'JobTitle', 'Department', 'UsageLocation', 'Type', 'Created')).DefaultView
        Write-GuiLog "$(@($result).Count) user(s)." 'info'
    }
}

function Get-EntraSelectedUser {
    param([hashtable]$Page, [switch]$One)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -eq 0 -or ($One -and $sel.Count -ne 1)) { Show-Message $(if ($One) { 'Select one user.' } else { 'Select one or more users.' }) 'Users' 'Warning'; return @() }
    return @($sel | ForEach-Object { $_.UserPrincipalName })
}

function Invoke-EntraUserAction {
    param([hashtable]$Page, [string]$Action)
    if (-not (Test-SignedIn)) { return }
    $users = Get-EntraSelectedUser -Page $Page
    if ($users.Count -eq 0) { return }
    Invoke-RepoScript -Name "$Action for $($users.Count) user(s)" -Path $Gui.Scripts.EntraUserSet -Params @{ User = $users; Action = $Action } -Context $Page -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        Show-ResultSecret -Result @($result)
        Invoke-EntraUsersRefresh -Page $pg
    }
}

function Invoke-EntraUserToGroup {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $users = Get-EntraSelectedUser -Page $Page
    if ($users.Count -eq 0) { return }
    Start-EntraGroupChoice -Context @{ Users = $users; Page = $Page } -OnChosen {
        param($groupId, $c)
        Invoke-RepoScript -Name "Add $($c.Users.Count) user(s) to a group" -Path $Gui.Scripts.EntraMember -Params @{ GroupId = $groupId; User = $c.Users }
    }
}

function Start-EntraGroupChoice {
    # Load the groups a person can add members to, then ask which one. OnChosen gets ($groupId, $Context).
    param([object]$Context, [scriptblock]$OnChosen)
    Start-Work -Name 'List groups' -Context @{ Inner = $Context; OnChosen = $OnChosen } -Script {
        $ErrorActionPreference = 'Stop'
        Get-EntraGroupInfo | Where-Object { $_.Source -eq 'Cloud' -and $_.Type -notmatch 'dynamic' -and $_.Type -ne 'Distribution' }
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        $opts = @(@($result) | ForEach-Object { @{ Value = $_.Id; Label = "$($_.DisplayName)  ($($_.Type))" } })
        if ($opts.Count -eq 0) { Show-Message 'No cloud groups that take members by hand.' 'Groups' 'Warning'; return }
        $gid = Show-ChoiceDialog -Title 'Add to group' -Text 'Which group? Dynamic groups and groups synced from AD are not listed: they do not take members by hand.' -Options $opts -OkText 'Add'
        if ($gid) { & $c.OnChosen $gid $c.Inner }
    }
}

function Invoke-EntraUserLicense {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $users = Get-EntraSelectedUser -Page $Page
    if ($users.Count -eq 0) { return }
    Start-Work -Name 'List licences' -Context @{ Users = $users; Page = $Page } -Script {
        $ErrorActionPreference = 'Stop'
        Get-EntraLicenseInfo
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        $opts = @(@($result) | ForEach-Object { @{ Value = "$($_.SkuId)"; Label = "$($_.Sku)  ($($_.Free) free of $($_.Total))" } })
        if ($opts.Count -eq 0) { Show-Message 'The tenant has no licences.' 'Licences' 'Warning'; return }
        $sku = Show-ChoiceDialog -Title 'Assign licence' -Text "Assign which licence to $($c.Users.Count) user(s)?" -Options $opts -OkText 'Assign'
        if (-not $sku) { return }
        $p = @{ User = $c.Users; Action = 'AssignLicense'; SkuId = $sku }
        $loc = Get-FormValue $c.Page.Form 'UsageLocation'
        if ($loc) { $p.UsageLocation = $loc.ToUpper() }
        Invoke-RepoScript -Name 'Assign licence' -Path $Gui.Scripts.EntraUserSet -Params $p -Context $c.Page -OnDone { param($r, $f, $pg) if (-not $f) { Invoke-EntraUsersRefresh -Page $pg } }
    }
}

function Invoke-EntraUserGroupList {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $users = Get-EntraSelectedUser -Page $Page -One
    if ($users.Count -ne 1) { return }
    Start-Work -Name "Groups of $($users[0])" -Argument @{ User = $users[0] } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-EntraUserGroupInfo -User $Job.User
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.GroupGrid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('DisplayName', 'Type', 'Id')).DefaultView
    }
}

# --- Groups -------------------------------------------------------------------
function New-EntraGroupsPage {
    $page = @{ Key = 'NavEntraGroups' }
    $root = New-PageRoot -Title 'Groups' -Lead 'Groups in the directory. Select one to see its members. Members are added here; removing them is done in the Entra admin center.'
    $null = $root.Children.Add((New-SearchBar -Page $page -Help 'Start of a group name. Empty lists the first 500.' -OnSearch { param($pg) Invoke-EntraGroupsRefresh -Page $pg }))
    $page.Grid = New-DataGrid -Height 300
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.Busy) { Invoke-EntraGroupMemberList -Page $pg } }
    $actions = @(
        @{ Text = 'Add members...'; Context = $page; Handler = { param($pg) Invoke-EntraGroupAddMember -Page $pg } }
        @{ Text = 'Show members';   Context = $page; Handler = { param($pg) Invoke-EntraGroupMemberList -Page $pg } }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Groups' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-EntraGroupsRefresh -Page $pg }),
        (New-ToolButton -Text 'Add group' -OnClick { Show-Page 'NavEntraAddGroup' }),
        (New-MenuButton -Items $actions))))
    $page.MemberGrid = New-DataGrid -Height 220
    $null = $root.Children.Add((New-TableCard -Title 'Members of the selected group' -Grid $page.MemberGrid))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Invoke-EntraGroupsRefresh -Page $pg } }
    $page.Root = $root
    return $page
}

function Invoke-EntraGroupsRefresh {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List groups' -Argument @{ Search = $Page.SearchBox.Text.Trim() } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $p = @{}; if ($Job.Search) { $p.Search = $Job.Search }
        Get-EntraGroupInfo @p
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Loaded = $true
        $pg.MemberGrid.ItemsSource = $null
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('DisplayName', 'Type', 'Source', 'Description', 'Rule', 'Created', 'Id')).DefaultView
        Write-GuiLog "$(@($result).Count) group(s)." 'info'
    }
}

function Invoke-EntraGroupMemberList {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { return }
    Start-Work -Name "Members of $($sel[0].DisplayName)" -Argument @{ GroupId = $sel[0].Id } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-EntraGroupMemberInfo -GroupId $Job.GroupId
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.MemberGrid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('DisplayName', 'Kind', 'UserPrincipalName', 'Id')).DefaultView
    }
}

function Invoke-EntraGroupAddMember {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { Show-Message 'Select one group.' 'Groups' 'Warning'; return }
    if ($sel[0].Type -match 'dynamic' -or $sel[0].Source -ne 'Cloud') { Show-Message "$($sel[0].DisplayName) does not take members by hand (dynamic, or synced from AD)." 'Groups' 'Warning'; return }
    $text = Show-InputDialog -Title "Add members to $($sel[0].DisplayName)" -Text 'Sign-in names (UPNs), one per line or separated by commas.' -Multiline -OkText 'Add'
    if (-not $text) { return }
    $users = Split-CommaList $text
    Invoke-RepoScript -Name "Add $($users.Count) member(s)" -Path $Gui.Scripts.EntraMember -Params @{ GroupId = $sel[0].Id; User = $users } -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Invoke-EntraGroupMemberList -Page $pg }
    }
}

# --- Add user -----------------------------------------------------------------
function New-EntraAddUserPage {
    $page = @{ Key = 'NavEntraAddUser'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'Add user' -Lead 'A cloud user, optionally in a group and with a licence. Leave the password empty for a random one; it is shown once when the user is created.'
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Identity' -Fields @(
        @{ Name = 'DisplayName'; Label = 'Display name'; Required = $true }
        @{ Name = 'UpnPrefix'; Label = 'Sign-in name (before the @)'; Required = $true }
        @{ Name = 'Domain'; Label = 'Domain'; Type = 'combo'; Required = $true; Help = 'Verified domains of the tenant. Loads when the page opens.' }
        @{ Name = 'GivenName'; Label = 'First name' }
        @{ Name = 'Surname'; Label = 'Last name' }
        @{ Name = 'JobTitle'; Label = 'Job title' }
        @{ Name = 'Department'; Label = 'Department' }
    )))
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Password' -Fields @(
        @{ Name = 'Password'; Label = 'Password (empty = random)'; Type = 'password' }
        @{ Name = 'PasswordConfirm'; Label = 'Confirm password'; Type = 'password' }
        @{ Name = 'MustChange'; Label = 'Must change it at first sign-in'; Type = 'check'; Default = $true; Span = 2 }
    )))
    $page.Groups = New-GroupPicker -Purpose 'membership (optional)'
    $access = New-FormSection -Form $form -Title 'Access' -Fields @(
        @{ Name = 'License'; Label = 'Licence'; Type = 'combo'; Options = @(@{ Value = ''; Label = 'None' }); Help = 'Free counts load when the page opens.' }
        @{ Name = 'UsageLocation'; Label = 'Usage location (two letters)'; Help = 'Needed for a licence. Example: US.' }
    )
    $null = $access.Child.Children.Add($page.Groups.Panel)
    $null = $root.Children.Add($access)
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create user' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-EntraAddUser -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-EntraAddUser -Page $c.Page -DryRun:$c.DryRun }))))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-EntraAddUserOptionLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-EntraAddUserOptionLoad {
    param([hashtable]$Page)
    Start-Work -Name 'Load domains and licences' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{ Domains = @(Get-EntraDomainInfo); Licenses = @(try { Get-EntraLicenseInfo } catch { Write-Warning "Licences: $($_.Exception.Message)" }) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Loaded = $true
        $default = @($r.Domains | Where-Object IsDefault | ForEach-Object Name) | Select-Object -First 1
        Add-ComboOption -Combo $pg.Form.Controls['Domain'] -Options @($r.Domains | ForEach-Object { $_.Name }) -Default "$default"
        Add-ComboOption -Combo $pg.Form.Controls['License'] -Options (@(@{ Value = ''; Label = 'None' }) + @($r.Licenses | Where-Object { $_ } | ForEach-Object { @{ Value = "$($_.SkuId)"; Label = "$($_.Sku)  ($($_.Free) free)" } })) -Default ''
    }
}

function Invoke-EntraAddUser {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $form = $Page.Form
    if (-not (Test-FormRequired -Form $form)) { return }
    $p1 = $form.Controls['Password']; $p2 = $form.Controls['PasswordConfirm']
    if ($p1.Password -ne $p2.Password) { Show-Message 'The two passwords do not match.' 'Password' 'Warning'; return }
    $p = @{ DisplayName = (Get-FormValue $form 'DisplayName'); UserPrincipalName = "$(Get-FormValue $form 'UpnPrefix')@$(Get-FormValue $form 'Domain')" }
    Add-FormParameter -Params $p -Form $form -Names @('GivenName', 'Surname', 'JobTitle', 'Department')
    if ($p1.SecurePassword.Length -gt 0) { $p.Password = $p1.SecurePassword }
    if (-not (Get-FormValue $form 'MustChange')) { $p.NoPasswordChange = $true }
    $loc = Get-FormValue $form 'UsageLocation'; if ($loc) { $p.UsageLocation = $loc.ToUpper() }
    $sku = Get-FormValue $form 'License'; if ($sku) { $p.LicenseSkuId = $sku }
    if ($sku -and -not $loc) { Show-Message 'A licence needs a usage location (two letters, for example US).' 'Licence' 'Warning'; return }
    $gid = Get-GroupPickerId $Page.Groups; if ($gid) { $p.GroupId = @($gid) }
    Invoke-RepoScript -Name "Create user $($p.UserPrincipalName)" -Path $Gui.Scripts.EntraUserNew -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        Show-ResultSecret -Result @($result)
        $pg.Form.Controls['Password'].Clear(); $pg.Form.Controls['PasswordConfirm'].Clear()
    }
}

# --- Add group ----------------------------------------------------------------
function New-EntraAddGroupPage {
    $page = @{ Key = 'NavEntraAddGroup'; Form = New-Form }
    $root = New-PageRoot -Title 'Add group' -Lead 'A cloud security group. If a group with the same name exists, that one is used instead of making a duplicate.'
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Group' -Fields @(
        @{ Name = 'DisplayName'; Label = 'Name'; Required = $true }
        @{ Name = 'Description'; Label = 'Description' }
        @{ Name = 'Member'; Label = 'Members (sign-in names, one per line or comma separated; optional)'; Type = 'multiline'; Span = 2 }
    )))
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create group' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-EntraAddGroup -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-EntraAddGroup -Page $c.Page -DryRun:$c.DryRun }))))
    $page.Root = $root
    return $page
}

function Invoke-EntraAddGroup {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form)) { return }
    $p = @{ DisplayName = (Get-FormValue $Page.Form 'DisplayName') }
    $d = Get-FormValue $Page.Form 'Description'; if ($d) { $p.Description = $d }
    $m = Split-CommaList (Get-FormValue $Page.Form 'Member'); if ($m.Count -gt 0) { $p.Member = $m }
    Invoke-RepoScript -Name "Create group $($p.DisplayName)" -Path $Gui.Scripts.EntraGroupNew -Params $p -DryRun:$DryRun
}

# --- User actions (bulk) ------------------------------------------------------
function New-EntraUserActionsPage {
    $page = @{ Key = 'NavEntraActions'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'User actions' -Lead 'One action on a list of users: paste sign-in names, pick the action, run. Each user gets a result row; one failure does not stop the rest.'
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Users and action' -Fields @(
        @{ Name = 'Users'; Label = 'Sign-in names (one per line or comma separated)'; Type = 'multiline'; Required = $true; Span = 2 }
        @{ Name = 'Action'; Label = 'Action'; Type = 'combo'; Default = 'RevokeSessions'; Options = @(
            @{ Value = 'BlockSignIn'; Label = 'Block sign-in' }, @{ Value = 'AllowSignIn'; Label = 'Allow sign-in' },
            @{ Value = 'RevokeSessions'; Label = 'Revoke sessions' }, @{ Value = 'ResetPassword'; Label = 'Reset password (random, shown once)' },
            @{ Value = 'AddToGroup'; Label = 'Add to the group below' }) }
        @{ Name = 'NoPasswordChange'; Label = 'Reset password: do not force a change at next sign-in'; Type = 'check'; Default = $false }
    )))
    $page.Groups = New-GroupPicker -Purpose 'Add to group'
    $gcard = New-Card -Title 'Group' -Subtitle 'Only used by Add to group.'
    $null = $gcard.Child.Children.Add($page.Groups.Panel)
    $null = $root.Children.Add($gcard)
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Run' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-EntraBulkAction -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-EntraBulkAction -Page $c.Page -DryRun:$c.DryRun }))))
    $page.Grid = New-DataGrid -Height 220
    $null = $root.Children.Add((New-TableCard -Title 'Results' -Grid $page.Grid))
    $page.Root = $root
    return $page
}

function Invoke-EntraBulkAction {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form)) { return }
    $users = Split-CommaList (Get-FormValue $Page.Form 'Users')
    $action = Get-FormValue $Page.Form 'Action'
    if ($action -eq 'AddToGroup') {
        $gid = Get-GroupPickerId $Page.Groups
        if (-not $gid) { Show-Message 'Search for and pick the group first.' 'Group' 'Warning'; return }
        $path = $Gui.Scripts.EntraMember; $p = @{ GroupId = $gid; User = $users }
    } else {
        $path = $Gui.Scripts.EntraUserSet; $p = @{ User = $users; Action = $action }
        if ($action -eq 'ResetPassword' -and (Get-FormValue $Page.Form 'NoPasswordChange')) { $p.NoPasswordChange = $true }
    }
    Invoke-RepoScript -Name "$action for $($users.Count) user(s)" -Path $path -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        Show-ResultGrid -Grid $pg.Grid -Result @($result) -Columns @('User', 'Group', 'Result')
        Show-ResultSecret -Result @($result)
    }
}
