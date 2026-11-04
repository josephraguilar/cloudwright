<#
.SYNOPSIS
    Send AVD diagnostics (host pools, workspaces, application groups) to a Log
    Analytics workspace, creating the workspace if asked.
.DESCRIPTION
    Adds a diagnostic setting named toolbox-avd with every log category. Other
    diagnostic settings on the resources are left alone. AVD Insights and the
    toolbox dashboard read this data; the first rows arrive after about 15
    minutes. Log Analytics bills per GB ingested (AVD logs are small).
.PARAMETER SubscriptionId
    Subscription of the AVD resources.
.PARAMETER ResourceId
    AVD resources to configure. Leave out with -AllAvdResources.
.PARAMETER AllAvdResources
    Every host pool, workspace and application group in the subscription.
.PARAMETER LogWorkspaceResourceId
    Resource ID of an existing Log Analytics workspace.
.PARAMETER WorkspaceResourceGroupName
    To create a workspace: its resource group (must exist).
.PARAMETER WorkspaceName
    To create a workspace: its name.
.PARAMETER Location
    To create a workspace: region. Defaults to the resource group's.
.EXAMPLE
    ./Set-AvdDiagnostic.ps1 -SubscriptionId <sub> -AllAvdResources -WorkspaceResourceGroupName rg-monitor -WorkspaceName law-avd
.NOTES
    Requires: Az.Accounts, Az.Monitor, Az.OperationalInsights, Az.Resources
    Status:   Untested
    Roles:    Monitoring Contributor on the AVD resources; Log Analytics Contributor
              to create the workspace.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter()] [string[]]$ResourceId = @(),
    [Parameter()] [switch]$AllAvdResources,
    [Parameter()] [string]$LogWorkspaceResourceId,
    [Parameter()] [string]$WorkspaceResourceGroupName,
    [Parameter()] [string]$WorkspaceName,
    [Parameter()] [string]$Location
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'OpsAdmin' 'OpsAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId

if (-not $LogWorkspaceResourceId) {
    if (-not ($WorkspaceResourceGroupName -and $WorkspaceName)) { throw 'Give -LogWorkspaceResourceId, or -WorkspaceResourceGroupName and -WorkspaceName to create one.' }
    if (-not $Location) { $Location = (Get-AzResourceGroup -Name $WorkspaceResourceGroupName -ErrorAction Stop).Location }
    $w = New-OpsLogWorkspace -ResourceGroupName $WorkspaceResourceGroupName -Name $WorkspaceName -Location $Location
    if (-not $w) { Write-Verbose 'WhatIf: the workspace does not exist yet, so the settings are not previewed.'; return }
    $LogWorkspaceResourceId = $w.ResourceId
}
$targets = if ($AllAvdResources) { @(Get-OpsDiagnosticInfo | ForEach-Object ResourceId) } else { $ResourceId }
if (@($targets).Count -eq 0) { throw 'No AVD resources: give -ResourceId or -AllAvdResources.' }
foreach ($id in $targets) {
    try { Set-OpsAvdDiagnostic -ResourceId $id -LogWorkspaceResourceId $LogWorkspaceResourceId }
    catch { Write-Warning "$(($id -split '/')[-1]): $($_.Exception.Message)"; [pscustomobject]@{ Resource = ($id -split '/')[-1]; Setting = 'Failed'; Workspace = $_.Exception.Message } }
}
