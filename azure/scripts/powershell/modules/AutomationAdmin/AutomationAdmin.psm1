#region Module setup ----------------------------------------------------------
#   WHAT   Azure Automation: accounts, their runbooks, recent jobs and output,
#          start a runbook (waiting for it if asked), import a new runbook from a
#          file (the repo's runbooks/ folder, for example).
#   WHY    Runbooks are the scheduled half of this toolbox: health checks and
#          clean-up jobs that run without anyone signed in. Seeing their last
#          run and starting one by hand covers most of the day-to-day.
#   GOTCHA An account is addressed by resource group and name; functions here
#          take its resource ID and split it. Importing never overwrites: a
#          runbook with the same name is refused. Nothing here deletes.
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Split-RbAccountId {
    param([string]$AccountId)
    $p = $AccountId -split '/'
    if ($p.Count -lt 9) { throw "'$AccountId' is not an Automation account resource ID." }
    return @{ ResourceGroupName = $p[4]; AutomationAccountName = $p[8] }
}
#endregion

#region Lookups ---------------------------------------------------------------
function Get-RunbookAccountInfo {
    <#
    .SYNOPSIS
        Automation accounts in the subscription.
    #>
    [CmdletBinding()]
    param()
    foreach ($a in @(Get-AzAutomationAccount) | Sort-Object ResourceGroupName, AutomationAccountName) {
        $id = "/subscriptions/$($a.SubscriptionId)/resourceGroups/$($a.ResourceGroupName)/providers/Microsoft.Automation/automationAccounts/$($a.AutomationAccountName)"
        [pscustomobject]@{ Name = $a.AutomationAccountName; ResourceGroupName = $a.ResourceGroupName; Location = $a.Location; State = "$($a.State)"; Id = $id }
    }
}

function Get-RunbookInfo {
    <#
    .SYNOPSIS
        Runbooks of one account with type, state and last change.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$AccountId)
    $a = Split-RbAccountId $AccountId
    foreach ($r in @(Get-AzAutomationRunbook @a) | Sort-Object Name) {
        [pscustomobject]@{
            Name = $r.Name; Type = "$($r.RunbookType)"; State = "$($r.State)"
            LastModified = $(if ($r.LastModifiedTime) { $r.LastModifiedTime.LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '' })
            Description = "$($r.Description)"; Account = $a.AutomationAccountName
        }
    }
}

function Get-RunbookJobInfo {
    <#
    .SYNOPSIS
        Jobs of the last -Hours hours in one account, newest first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$AccountId,
        [Parameter()] [ValidateRange(1, 720)] [int]$Hours = 72
    )
    $a = Split-RbAccountId $AccountId
    $jobs = @(Get-AzAutomationJob @a -StartTime ([datetimeoffset](Get-Date).AddHours(-$Hours)))
    foreach ($j in $jobs | Sort-Object CreationTime -Descending) {
        [pscustomobject]@{
            Runbook = $j.RunbookName; Status = "$($j.Status)"
            Started = $(if ($j.StartTime) { $j.StartTime.LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '' })
            Ended = $(if ($j.EndTime) { $j.EndTime.LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '' })
            RunOn = "$($j.HybridWorker)"; JobId = "$($j.JobId)"
        }
    }
}

function Get-RunbookJobOutput {
    <#
    .SYNOPSIS
        Output, warning and error records of one job, as text lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$AccountId,
        [Parameter(Mandatory)] [guid]$JobId
    )
    $a = Split-RbAccountId $AccountId
    foreach ($rec in @(Get-AzAutomationJobOutput @a -Id $JobId -Stream Any) | Sort-Object Time) {
        $text = "$($rec.Summary)"
        try { $full = Get-AzAutomationJobOutputRecord @a -JobId $JobId -Id $rec.StreamRecordId -ErrorAction Stop; if ($full.Value -and $full.Value.ContainsKey('value')) { $text = "$($full.Value['value'])" } } catch { Write-Verbose 'Using the summary for this record.' }
        [pscustomobject]@{ Time = $rec.Time.LocalDateTime.ToString('HH:mm:ss'); Stream = "$($rec.Type)"; Text = $text }
    }
}
#endregion

#region Start and import ------------------------------------------------------
function Start-RunbookNow {
    <#
    .SYNOPSIS
        Start a published runbook with parameters. -Wait waits up to
        -MaxWaitMinutes and returns the job's status and output.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$AccountId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [hashtable]$Parameter = @{},
        [Parameter()] [string]$RunOn,
        [Parameter()] [switch]$Wait,
        [Parameter()] [ValidateRange(1, 180)] [int]$MaxWaitMinutes = 30
    )
    $a = Split-RbAccountId $AccountId
    if (-not $PSCmdlet.ShouldProcess("$($a.AutomationAccountName)/$Name", 'Start runbook')) { return }
    $p = @{ Name = $Name } + $a
    if ($Parameter.Count) { $p.Parameters = $Parameter }
    if ($RunOn) { $p.RunOn = $RunOn }
    $job = Start-AzAutomationRunbook @p
    Write-Verbose "Started $Name (job $($job.JobId))."
    if (-not $Wait) { return [pscustomobject]@{ Runbook = $Name; Status = "$($job.Status)"; JobId = "$($job.JobId)" } }
    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    do {
        Start-Sleep -Seconds 10
        $job = Get-AzAutomationJob @a -Id $job.JobId
        Write-Verbose "  $Name is $($job.Status)."
    } while ("$($job.Status)" -notin 'Completed', 'Failed', 'Stopped', 'Suspended' -and (Get-Date) -lt $deadline)
    $out = @(Get-RunbookJobOutput -AccountId $AccountId -JobId $job.JobId)
    foreach ($o in $out | Select-Object -Last 30) { Write-Verbose "  [$($o.Stream)] $($o.Text)" }
    [pscustomobject]@{ Runbook = $Name; Status = "$($job.Status)"; JobId = "$($job.JobId)"; Output = (@($out | ForEach-Object { "[$($_.Stream)] $($_.Text)" }) -join "`n") }
}

function Import-RunbookFile {
    <#
    .SYNOPSIS
        Import a .ps1 as a new PowerShell 7.2 runbook and publish it. A runbook
        with the same name is refused rather than overwritten.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$AccountId,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter()] [string]$Name,
        [Parameter()] [ValidateSet('PowerShell72', 'PowerShell')] [string]$Type = 'PowerShell72',
        [Parameter()] [string]$Description
    )
    if (-not (Test-Path $Path)) { throw "File not found: $Path" }
    $a = Split-RbAccountId $AccountId
    if (-not $Name) { $Name = [System.IO.Path]::GetFileNameWithoutExtension($Path) }
    $exists = Get-AzAutomationRunbook @a -Name $Name -ErrorAction SilentlyContinue
    if ($exists) { throw "$($a.AutomationAccountName) already has a runbook named $Name. Rename the file or update it in the portal; importing does not overwrite." }
    if (-not $PSCmdlet.ShouldProcess("$($a.AutomationAccountName)/$Name", "Import $(Split-Path $Path -Leaf) as a $Type runbook and publish it")) { return }
    $p = @{ Path = $Path; Name = $Name; Type = $Type; Published = $true } + $a
    if ($Description) { $p.Description = $Description }
    $null = Import-AzAutomationRunbook @p
    Write-Verbose "Imported and published $Name."
    Get-RunbookInfo -AccountId $AccountId | Where-Object Name -eq $Name
}
#endregion
