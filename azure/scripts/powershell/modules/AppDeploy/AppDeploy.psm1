#region Module setup ----------------------------------------------------------
#   WHAT   Everything that runs inside VMs: pick targets (a host pool's hosts, or
#          named VMs), run a script on all of them in parallel through managed Run
#          Commands, and the things built on that: a script library, winget
#          installs, shell apps (your own install script plus a detection check),
#          certificates. Plus MSIX app attach packages, Key Vault certificates, and
#          a local JSON store for app groups, shell apps, script groups and
#          saved deployments.
#   WHY    One runner means one place that handles "VM is off", time-outs and
#          output for every in-guest action, and the deployment status page can
#          read the same run commands back.
#   GOTCHA Run commands keep a stable name per action (toolbox-winget,
#          toolbox-script-<name>, ...): Azure keeps each as a child resource of the
#          VM with its last result, so reusing the name updates it instead of
#          piling up new ones. Nothing here removes a run command, a package, a
#          certificate or a store entry. The store is a gitignored file
#          (toolbox.local.json); edit it by hand to drop an entry.
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:HostConfig = Join-Path $PSScriptRoot 'hostconfig'
$script:PowerShellRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:DefaultStore = Join-Path $script:PowerShellRoot 'toolbox.local.json'
$script:LibraryRoots = @(
    @{ Source = 'Repo';  Path = (Join-Path $script:PowerShellRoot 'library' 'windows') }
    @{ Source = 'Local'; Path = (Join-Path $script:PowerShellRoot 'library' 'local') }
)
#endregion

#region Targets and the runner -------------------------------------------------
function Resolve-GuestTarget {
    <#
    .SYNOPSIS
        Turn "rg/name" strings, or a host pool, into VM rows with power state.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string[]]$VM = @(),
        [Parameter()] [string]$HostPoolName,
        [Parameter()] [string]$HostPoolResourceGroupName
    )
    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($v in $VM) {
        $p = $v -split '[/|]'
        if ($p.Count -ne 2) { throw "VM '$v' must be written resource-group/name." }
        $pairs.Add(@{ Rg = $p[0]; Name = $p[1] })
    }
    if ($HostPoolName) {
        foreach ($h in @(Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName)) {
            $id = "$($h.ResourceId)" -split '/'
            if ($id.Count -ge 9) { $pairs.Add(@{ Rg = $id[4]; Name = $id[8] }) }
        }
    }
    if ($pairs.Count -eq 0) { throw 'No target VMs: give -VM or a host pool.' }
    foreach ($t in $pairs | Sort-Object { "$($_.Rg)/$($_.Name)" } -Unique) {
        $s = Get-AzVM -ResourceGroupName $t.Rg -Name $t.Name -Status -ErrorAction Stop
        $power = (@($s.Statuses | Where-Object { $_.Code -like 'PowerState/*' }) | Select-Object -First 1).Code -replace '^PowerState/', ''
        [pscustomobject]@{ ResourceGroupName = $t.Rg; Name = $t.Name; Location = $s.Location; Power = $power; OsType = "$($s.OsName)" }
    }
}

function Invoke-GuestRunCommand {
    <#
    .SYNOPSIS
        Run one script on many VMs at once through managed Run Commands and wait
        for all of them. VMs that are not running are skipped and reported.
    .PARAMETER Target
        Rows from Resolve-GuestTarget.
    .PARAMETER Name
        Run command name (letters, digits, hyphens). Reused names update in place.
    .PARAMETER ScriptText
        The PowerShell to run (Windows PowerShell 5.1, as SYSTEM).
    .PARAMETER Parameter
        Plain parameters for the script's param block.
    .PARAMETER ProtectedParameter
        Secret parameters: encrypted in transit, never shown in the result.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object[]]$Target,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9-]{1,60}$')] [string]$Name,
        [Parameter(Mandatory)] [string]$ScriptText,
        [Parameter()] [hashtable]$Parameter = @{},
        [Parameter()] [hashtable]$ProtectedParameter = @{},
        [Parameter()] [ValidateRange(60, 5400)] [int]$TimeoutSeconds = 1800
    )
    $running = @($Target | Where-Object Power -eq 'running')
    foreach ($t in @($Target | Where-Object Power -ne 'running')) {
        Write-Warning "$($t.Name) is $($t.Power); skipped."
        [pscustomobject]@{ VM = $t.Name; ResourceGroupName = $t.ResourceGroupName; State = "Skipped ($($t.Power))"; ExitCode = ''; Output = ''; Error = '' }
    }
    if ($running.Count -eq 0) { return }
    if (-not $PSCmdlet.ShouldProcess(($running.Name -join ', '), "Run '$Name' inside the VM(s)")) { return }
    $plist = @($Parameter.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = "$($_.Value)" } })
    $slist = @($ProtectedParameter.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = "$($_.Value)" } })
    $canJob = (Get-Command Set-AzVMRunCommand).Parameters.ContainsKey('AsJob')
    $jobs = @{}
    foreach ($t in $running) {
        $p = @{ ResourceGroupName = $t.ResourceGroupName; VMName = $t.Name; RunCommandName = $Name; Location = $t.Location; SourceScript = $ScriptText; TimeoutInSecond = $TimeoutSeconds }
        if ($plist.Count) { $p.Parameter = $plist }
        if ($slist.Count) { $p.ProtectedParameter = $slist }
        Write-Verbose "Starting '$Name' on $($t.Name)."
        if ($canJob) { $jobs[$t.Name] = Set-AzVMRunCommand @p -AsJob }
        else { try { $null = Set-AzVMRunCommand @p } catch { Write-Warning "$($t.Name): $($_.Exception.Message)" } }
    }
    if ($canJob -and $jobs.Count) {
        Write-Verbose "Waiting for $($jobs.Count) VM(s)."
        $null = $jobs.Values | Wait-Job -Timeout ($TimeoutSeconds + 300)
        foreach ($k in $jobs.Keys) {
            $j = $jobs[$k]
            if ($j.State -eq 'Failed') { Write-Warning "$k`: $(($j | Receive-Job -ErrorAction SilentlyContinue 2>&1 | Out-String).Trim())" }
            else { $null = $j | Receive-Job -ErrorAction SilentlyContinue }
        }
    }
    foreach ($t in $running) {
        $rc = Get-AzVMRunCommand -ResourceGroupName $t.ResourceGroupName -VMName $t.Name -RunCommandName $Name -Expand InstanceView -ErrorAction SilentlyContinue
        $iv = if ($rc) { $rc.InstanceView } else { $null }
        $out = if ($iv) { "$($iv.Output)".Trim() } else { '' }
        foreach ($line in ($out -split "`r?`n" | Select-Object -First 40)) { if ($line) { Write-Verbose "  [$($t.Name)] $line" } }
        [pscustomobject]@{
            VM = $t.Name; ResourceGroupName = $t.ResourceGroupName
            State = $(if ($iv) { "$($iv.ExecutionState)" } else { 'Unknown' })
            ExitCode = $(if ($iv) { "$($iv.ExitCode)" } else { '' })
            Output = $(if ($out.Length -gt 4000) { $out.Substring($out.Length - 4000) } else { $out })
            Error = $(if ($iv) { "$($iv.Error)".Trim() } else { '' })
        }
    }
}

function Get-GuestRunCommandInfo {
    <#
    .SYNOPSIS
        The managed run commands on VMs with their last result: what ran, when,
        and whether it worked. The deployment status page reads this.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Target)
    foreach ($t in $Target) {
        foreach ($rc in @(Get-AzVMRunCommand -ResourceGroupName $t.ResourceGroupName -VMName $t.Name -ErrorAction SilentlyContinue)) {
            $full = Get-AzVMRunCommand -ResourceGroupName $t.ResourceGroupName -VMName $t.Name -RunCommandName $rc.Name -Expand InstanceView -ErrorAction SilentlyContinue
            $iv = if ($full) { $full.InstanceView } else { $null }
            [pscustomobject]@{
                VM = $t.Name; RunCommand = $rc.Name
                State = $(if ($iv) { "$($iv.ExecutionState)" } else { '' })
                ExitCode = $(if ($iv) { "$($iv.ExitCode)" } else { '' })
                Started = $(if ($iv -and $iv.StartTime) { ([datetime]$iv.StartTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' })
                Ended = $(if ($iv -and $iv.EndTime) { ([datetime]$iv.EndTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' })
                LastLine = $(if ($iv) { (@("$($iv.Output)".Trim() -split "`r?`n") | Select-Object -Last 1) } else { '' })
            }
        }
    }
}
#endregion

#region Script library ----------------------------------------------------------
function Get-GuestScriptLibrary {
    <#
    .SYNOPSIS
        Scripts that can run inside VMs: library/windows in the repo, and
        library/local (gitignored) for your own. Synopsis and parameters are read
        from each file.
    #>
    [CmdletBinding()]
    param()
    foreach ($root in $script:LibraryRoots) {
        if (-not (Test-Path $root.Path)) { continue }
        foreach ($f in Get-ChildItem -Path $root.Path -Filter '*.ps1' | Sort-Object Name) {
            $text = Get-Content $f.FullName -Raw
            $syn = if ($text -match '(?s)\.SYNOPSIS\s*\r?\n\s*(.+?)\r?\n\s*(\.|#>)') { ($Matches[1] -replace '\s+', ' ').Trim() } else { '' }
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
            $params = @()
            if ($ast.ParamBlock) {
                $params = @($ast.ParamBlock.Parameters | ForEach-Object {
                    $n = $_.Name.VariablePath.UserPath
                    if ($_.DefaultValue) { "$n=$($_.DefaultValue.Extent.Text.Trim([char]39, [char]34))" } else { $n } })
            }
            [pscustomobject]@{ Name = $f.BaseName; Synopsis = $syn; Parameters = ($params -join ', '); Source = $root.Source; Path = $f.FullName }
        }
    }
}
#endregion

#region Local store -------------------------------------------------------------
#   WHAT   App groups, shell apps, script groups, runbook groups and saved
#          deployments live in one gitignored JSON file next to the scripts.
#   WHY    They are your definitions, not Azure resources; keeping them local
#          means nothing client-specific lands in the repo.
$script:StoreKinds = @('AppGroups', 'ShellApps', 'ScriptGroups', 'RunbookGroups', 'Deployments')

function Get-ToolboxStore {
    <#
    .SYNOPSIS
        The local store as a hashtable of kind -> name -> definition.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()] [string]$Path = $script:DefaultStore)
    $store = @{}
    foreach ($k in $script:StoreKinds) { $store[$k] = @{} }
    if (Test-Path $Path) {
        $raw = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
        foreach ($k in $script:StoreKinds) { if ($raw -and $raw.ContainsKey($k) -and $raw[$k]) { $store[$k] = $raw[$k] } }
    }
    return $store
}

function Set-ToolboxStoreItem {
    <#
    .SYNOPSIS
        Add or replace one definition in the local store. Never removes one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidateSet('AppGroups', 'ShellApps', 'ScriptGroups', 'RunbookGroups', 'Deployments')] [string]$Kind,
        [Parameter(Mandatory)] [ValidatePattern('^[\w .()-]{1,60}$')] [string]$Name,
        [Parameter(Mandatory)] [hashtable]$Value,
        [Parameter()] [string]$Path = $script:DefaultStore
    )
    $store = Get-ToolboxStore -Path $Path
    $verb = if ($store[$Kind].ContainsKey($Name)) { 'Replace' } else { 'Add' }
    if (-not $PSCmdlet.ShouldProcess("$Kind/$Name", "$verb in $(Split-Path $Path -Leaf)")) { return }
    $Value['Saved'] = (Get-Date).ToString('u')
    $store[$Kind][$Name] = $Value
    $store | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding utf8
    Write-Verbose "$verb $Kind/$Name in $Path."
    [pscustomobject]@{ Kind = $Kind; Name = $Name; Result = $verb }
}
#endregion

#region winget and shell apps ---------------------------------------------------
function Find-WingetPackage {
    <#
    .SYNOPSIS
        Search the winget catalog by running winget on one VM (it must be running
        and have App Installer). Returns Name, Id, Version, Source rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [Parameter(Mandatory)] [string]$Query
    )
    $text = Get-Content (Join-Path $script:HostConfig 'Invoke-Winget.ps1') -Raw
    $r = @(Invoke-GuestRunCommand -Target @($Target) -Name 'toolbox-winget-search' -ScriptText $text -Parameter @{ Action = 'Search'; Query = $Query } -TimeoutSeconds 300 -Confirm:$false) | Select-Object -Last 1
    if (-not $r -or $r.State -ne 'Succeeded') { throw "winget search on $($Target.Name) did not succeed: $($r.State) $($r.Output) $($r.Error)" }
    $rows = $r.Output -split "`r?`n"
    $start = [array]::IndexOf($rows, '---ROWS---')
    if ($start -lt 0) { throw "Unexpected winget output: $($r.Output)" }
    foreach ($l in $rows[($start + 1)..($rows.Count - 1)]) {
        $p = $l -split '\|'
        if ($p.Count -ge 3 -and $p[1]) { [pscustomobject]@{ Name = $p[0]; Id = $p[1]; Version = $p[2]; Source = $(if ($p.Count -ge 4) { $p[3] } else { '' }) } }
    }
}

function Install-WingetPackage {
    <#
    .SYNOPSIS
        Install (or upgrade) winget packages machine-wide on the target VMs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object[]]$Target,
        [Parameter(Mandatory)] [string[]]$Id,
        [Parameter()] [switch]$Upgrade
    )
    $text = Get-Content (Join-Path $script:HostConfig 'Invoke-Winget.ps1') -Raw
    if (-not $PSCmdlet.ShouldProcess(($Target.Name -join ', '), "$(if ($Upgrade) { 'Upgrade' } else { 'Install' }) $($Id -join ', ')")) { return }
    Invoke-GuestRunCommand -Target $Target -Name 'toolbox-winget' -ScriptText $text -Parameter @{ Action = $(if ($Upgrade) { 'Upgrade' } else { 'Install' }); Id = ($Id -join ',') } -Confirm:$false
}

function New-ShellAppScript {
    <#
    .SYNOPSIS
        One script from a shell app's detection and install blocks: detect, stop if
        present, install, detect again. Exit 1 when detection still fails.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string; changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Detect,
        [Parameter(Mandatory)] [string]$Install
    )
    $safe = $Name -replace "'", "''"
    return @"
`$ErrorActionPreference = 'Stop'
`$detect = { $Detect }
if (& `$detect) { '$safe is already installed.'; exit 0 }
& { $Install }
if (& `$detect) { '$safe installed.' } else { '$safe install ran, but detection still says it is missing.'; exit 1 }
"@
}

function Install-ShellApp {
    <#
    .SYNOPSIS
        Run a shell app (from the local store, or given blocks) on the target VMs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object[]]$Target,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [string]$Detect,
        [Parameter()] [string]$Install,
        [Parameter()] [string]$StorePath = $script:DefaultStore
    )
    if (-not $Install) {
        $store = Get-ToolboxStore -Path $StorePath
        if (-not $store.ShellApps.ContainsKey($Name)) { throw "No shell app '$Name' in $(Split-Path $StorePath -Leaf)." }
        $Detect = $store.ShellApps[$Name].Detect; $Install = $store.ShellApps[$Name].Install
    }
    if (-not $Detect) { $Detect = '$false' }
    $text = New-ShellAppScript -Name $Name -Detect $Detect -Install $Install
    if (-not $PSCmdlet.ShouldProcess(($Target.Name -join ', '), "Install shell app $Name")) { return }
    $rcName = 'toolbox-app-' + (($Name -replace '[^A-Za-z0-9-]', '-').ToLower() -replace '-+', '-').Trim('-')
    Invoke-GuestRunCommand -Target $Target -Name $rcName.Substring(0, [Math]::Min(60, $rcName.Length)) -ScriptText $text -Confirm:$false
}
#endregion

#region Certificates -------------------------------------------------------------
function Get-KvCertificateInfo {
    <#
    .SYNOPSIS
        Certificates in every Key Vault the account can read, soonest expiry first.
    #>
    [CmdletBinding()]
    param([Parameter()] [int]$WarnDays = 30)
    $rows = foreach ($v in @(Get-AzKeyVault)) {
        try { $certs = @(Get-AzKeyVaultCertificate -VaultName $v.VaultName -ErrorAction Stop) }
        catch { Write-Warning "$($v.VaultName): $($_.Exception.Message.Split([char]10)[0])"; continue }
        foreach ($c in $certs) {
            $exp = $c.Expires
            $days = if ($exp) { [int][math]::Floor(([datetime]$exp - (Get-Date)).TotalDays) } else { $null }
            [pscustomobject]@{
                Vault = $v.VaultName; Name = $c.Name; Expires = $(if ($exp) { ([datetime]$exp).ToString('yyyy-MM-dd') } else { '' })
                DaysLeft = $days; Status = $(if ($null -eq $days) { '' } elseif ($days -lt 0) { 'EXPIRED' } elseif ($days -le $WarnDays) { 'Expiring soon' } else { 'OK' })
                Enabled = [bool]$c.Enabled; Thumbprint = "$($c.Thumbprint)"; ResourceGroupName = $v.ResourceGroupName
            }
        }
    }
    $rows | Sort-Object @{ e = { if ($null -eq $_.DaysLeft) { 99999 } else { $_.DaysLeft } } }
}

function Import-KvCertificate {
    <#
    .SYNOPSIS
        Import a PFX into a Key Vault as a certificate. An existing name gets a
        new version (the old one stays).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VaultName,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9-]{1,127}$')] [string]$Name,
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [securestring]$Password
    )
    if (-not (Test-Path $FilePath)) { throw "File not found: $FilePath" }
    if (-not $PSCmdlet.ShouldProcess("$VaultName/$Name", "Import $(Split-Path $FilePath -Leaf)")) { return }
    Write-Verbose "Importing $(Split-Path $FilePath -Leaf) into $VaultName as $Name."
    $c = Import-AzKeyVaultCertificate -VaultName $VaultName -Name $Name -FilePath $FilePath -Password $Password
    [pscustomobject]@{ Vault = $VaultName; Name = $Name; Thumbprint = "$($c.Thumbprint)"; Expires = "$($c.Expires)" }
}

function Install-GuestCertificate {
    <#
    .SYNOPSIS
        Put a .pfx or .cer from this computer into the local machine store of the
        target VMs. The file and password travel as protected parameters.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object[]]$Target,
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter()] [securestring]$Password,
        [Parameter()] [ValidateSet('My', 'Root', 'CA', 'TrustedPublisher')] [string]$StoreName = 'My'
    )
    if (-not (Test-Path $FilePath)) { throw "File not found: $FilePath" }
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $FilePath))
    if ($bytes.Length -gt 120KB) { throw 'The certificate file is over 120 KB, too big to send through a run command.' }
    $isPfx = [System.IO.Path]::GetExtension($FilePath) -in '.pfx', '.p12'
    if ($isPfx -and -not $Password) { throw 'A PFX needs its password.' }
    if (-not $PSCmdlet.ShouldProcess(($Target.Name -join ', '), "Import $(Split-Path $FilePath -Leaf) into LocalMachine\$StoreName")) { return }
    $prot = @{ CertificateBase64 = [Convert]::ToBase64String($bytes) }
    if ($isPfx) { $prot.PfxPassword = [System.Net.NetworkCredential]::new('', $Password).Password }
    $text = Get-Content (Join-Path $script:HostConfig 'Install-Certificate.ps1') -Raw
    Invoke-GuestRunCommand -Target $Target -Name 'toolbox-certificate' -ScriptText $text -Parameter @{ StoreName = $StoreName } -ProtectedParameter $prot -TimeoutSeconds 300 -Confirm:$false
}
#endregion

#region MSIX app attach ----------------------------------------------------------
#   WHY    App attach mounts an app image per user at sign-in instead of
#          installing it on every host. Packages are regional resources; a package
#          is assigned to host pools and to users or groups.
#   GOTCHA Assigning host pools replaces the list, so Add-AppAttachPackageHostPool
#          merges the existing pools with the new one. Unassigning a pool and
#          removing a package or a user are not offered.
function Get-AppAttachPackageInfo {
    <#
    .SYNOPSIS
        App attach packages with state, registration and assigned host pools.
    #>
    [CmdletBinding()]
    param()
    foreach ($res in @(Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/appAttachPackages' -ErrorAction SilentlyContinue) | Sort-Object ResourceGroupName, Name) {
        $p = Get-AzWvdAppAttachPackage -ResourceGroupName $res.ResourceGroupName -Name $res.Name
        [pscustomobject]@{
            Name = $p.Name; DisplayName = "$($p.ImageDisplayName)"; Version = "$($p.ImageVersion)"
            Active = [bool]$p.ImageIsActive; Registration = $(if ($p.ImageIsRegularRegistration) { 'At sign-in' } else { 'On demand' })
            HostPools = (@($p.HostPoolReference | ForEach-Object { ("$_" -split '/')[-1] }) -join ', ')
            Path = "$($p.ImagePath)"; PackageFamily = "$($p.ImagePackageFamilyName)"
            ResourceGroupName = $res.ResourceGroupName; Location = $res.Location; Id = $p.Id
        }
    }
}

function New-AppAttachPackageResource {
    <#
    .SYNOPSIS
        Add an MSIX/AppX image (or App-V package) on a file share as an app attach
        package, assigned to the given host pool.
    .PARAMETER PackageFullName
        When the image holds more than one package (x64 and x86), which one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$HostPoolResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter(Mandatory)] [ValidatePattern('^\\\\')] [string]$Path,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9._-]{3,64}$')] [string]$Name,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter()] [switch]$Inactive,
        [Parameter()] [switch]$RegisterAtSignIn,
        [Parameter()] [string]$PackageFullName
    )
    $existing = Get-AzWvdAppAttachPackage -ResourceGroupName $HostPoolResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "Package $Name exists."; return $existing }
    $pool = Get-AzWvdHostPool -ResourceGroupName $HostPoolResourceGroupName -Name $HostPoolName
    Write-Verbose "Reading the package from $Path (a running session host reads it)."
    $info = @(Import-AzWvdAppAttachPackageInfo -HostPoolName $HostPoolName -ResourceGroupName $HostPoolResourceGroupName -Path $Path)
    if ($PackageFullName) { $info = @($info | Where-Object { "$($_.ImagePackageFullName)" -like "*$PackageFullName*" }) }
    if ($info.Count -eq 0) { throw "No package found in $Path$(if ($PackageFullName) { " matching $PackageFullName" })." }
    if ($info.Count -gt 1) { throw "The image holds $($info.Count) packages; pass -PackageFullName with one of: $(@($info | ForEach-Object { $_.ImagePackageFullName }) -join ', ')" }
    if (-not $PSCmdlet.ShouldProcess($Name, "Add app attach package $DisplayName for $HostPoolName")) { return }
    $p = @{
        AppAttachPackage = $info[0]; Name = $Name; ResourceGroupName = $HostPoolResourceGroupName; Location = $pool.Location
        FailHealthCheckOnStagingFailure = 'NeedsAssistance'; ImageIsRegularRegistration = [bool]$RegisterAtSignIn
        ImageDisplayName = $DisplayName; ImageIsActive = (-not $Inactive)
    }
    $null = New-AzWvdAppAttachPackage @p
    $null = Update-AzWvdAppAttachPackage -Name $Name -ResourceGroupName $HostPoolResourceGroupName -Location $pool.Location -HostPoolReference @($pool.Id)
    Write-Verbose "Added $Name and assigned it to $HostPoolName. Grant a group access next."
    Get-AppAttachPackageInfo | Where-Object { $_.Name -eq $Name -and $_.ResourceGroupName -eq $HostPoolResourceGroupName }
}

function Set-AppAttachPackageState {
    <#
    .SYNOPSIS
        Make a package active or inactive, and register it at sign-in or on demand.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [Nullable[bool]]$Active,
        [Parameter()] [Nullable[bool]]$RegisterAtSignIn
    )
    $pkg = Get-AzWvdAppAttachPackage -ResourceGroupName $ResourceGroupName -Name $Name
    $p = @{ ResourceGroupName = $ResourceGroupName; Name = $Name; Location = $pkg.Location }
    $what = @()
    if ($null -ne $Active) { $p.IsActive = [bool]$Active; $what += $(if ($Active) { 'active' } else { 'inactive' }) }
    if ($null -ne $RegisterAtSignIn) { $p.IsRegularRegistration = [bool]$RegisterAtSignIn; $what += $(if ($RegisterAtSignIn) { 'register at sign-in' } else { 'register on demand' }) }
    if ($what.Count -eq 0) { return }
    if (-not $PSCmdlet.ShouldProcess($Name, ($what -join ', '))) { return }
    $null = Update-AzWvdAppAttachPackage @p
    Write-Verbose "$Name`: $($what -join ', ')."
}

function Add-AppAttachPackageHostPool {
    <#
    .SYNOPSIS
        Assign a package to one more host pool, keeping the ones it has.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$HostPoolId
    )
    $pkg = Get-AzWvdAppAttachPackage -ResourceGroupName $ResourceGroupName -Name $Name
    $now = @($pkg.HostPoolReference | ForEach-Object { "$_" })
    if ($now -contains $HostPoolId) { Write-Verbose "$Name is already assigned to that pool."; return }
    if (-not $PSCmdlet.ShouldProcess($Name, "Assign to host pool $(($HostPoolId -split '/')[-1])")) { return }
    $null = Update-AzWvdAppAttachPackage -ResourceGroupName $ResourceGroupName -Name $Name -Location $pkg.Location -HostPoolReference (@($now) + $HostPoolId)
}

function Grant-AppAttachPackageAccess {
    <#
    .SYNOPSIS
        Let a group (or user) use a package: Desktop Virtualization User on it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ObjectId
    )
    $pkg = Get-AzWvdAppAttachPackage -ResourceGroupName $ResourceGroupName -Name $Name
    $has = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName 'Desktop Virtualization User' -Scope $pkg.Id -ErrorAction SilentlyContinue
    if ($has) { Write-Verbose 'Access already granted.'; return }
    if (-not $PSCmdlet.ShouldProcess($Name, "Grant Desktop Virtualization User to $ObjectId")) { return }
    $null = New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName 'Desktop Virtualization User' -Scope $pkg.Id
    Write-Verbose "Granted $ObjectId access to $Name."
}
#endregion
