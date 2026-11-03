BeforeAll {
    $modules = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules'
    Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
    $script:ManifestPath = Join-Path $modules 'OnboardingHelpers' 'OnboardingHelpers.psd1'
    Import-Module $script:ManifestPath -Force

    $json = Get-Content (Join-Path $PSScriptRoot '..' 'config' 'msp.settings.example.json') -Raw | ConvertFrom-Json
    $json.msp.supportEmail = 'support@msp.example'; $json.msp.adminUpn = 'tech@msp.example'
    $settingsPath = Join-Path $TestDrive 'msp.json'
    $json | ConvertTo-Json -Depth 6 | Set-Content $settingsPath
    $script:Settings = Get-M365Settings -Path $settingsPath -Force
    $script:Client = Get-M365ClientConfig -Path (Join-Path $PSScriptRoot '..' 'config' 'clients' 'example.client.json') -Settings $script:Settings
    $script:Plan = @(Get-OnboardingPlan -Client $script:Client -Settings $script:Settings)
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

Describe 'OnboardingHelpers module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    Context 'Get-OnboardingPlan' {
        It 'keeps checklist order: section 1 (Internal) before section 5 (Tenant)' {
            $phases = $script:Plan.Phase | Select-Object -Unique
            $phases | Should -Be @('Internal', 'Tenant')
        }
        It 'keeps the welcome letter manual until the text is approved' {
            $s = $script:Plan | Where-Object Id -eq '5.14'
            $s.Kind | Should -Be 'Manual'
            $s.Note | Should -Match 'Deferred'
        }
        It 'runs the security baseline audit as step 5.15 against the client tenant, named explicitly' {
            $s = $script:Plan | Where-Object Id -eq '5.15'
            $s.Kind | Should -Be 'Assisted'
            $s.Invocations[0].Organization | Should -Be 'contoso.onmicrosoft.com'
            $s.Invocations[0].TenantId | Should -Not -BeNullOrEmpty
        }
        It 'names the tenant on every invocation of a script that takes -Organization (ours for Internal, the client''s for Tenant)' {
            foreach ($s in $script:Plan | Where-Object { $_.Kind -ne 'Manual' -and $_.Applies }) {
                $cmd = Get-Command (Join-Path $script:RepoRoot $s.Script)
                if (-not $cmd.Parameters.ContainsKey('Organization')) { continue }
                foreach ($inv in $s.Invocations) {
                    $inv.Contains('Organization') | Should -BeTrue -Because "$($s.Id) must name its tenant"
                    $expected = if ($s.Phase -eq 'Internal') { $script:Settings.msp.homeTenantId } else { 'contoso.onmicrosoft.com' }
                    $inv['Organization'] | Should -Be $expected -Because "$($s.Id)"
                }
            }
        }
        It 'checks GDAP (5.7) by tenant id, never by name, and fails when nothing is active' {
            $s = $script:Plan | Where-Object Id -eq '5.7'
            $s.Invocations[0].Contains('CustomerTenantId') | Should -BeTrue
            $s.Invocations[0].Contains('CustomerName') | Should -BeFalse
            & $s.Expect @([pscustomobject]@{ Status = 'expired' }) | Should -Match 'No active'
            & $s.Expect @([pscustomobject]@{ Status = 'active' }) | Should -BeNullOrEmpty
        }
        It 'says in the step name that break-glass also gets Global Administrator and CA exclusions' {
            ($script:Plan | Where-Object Id -eq '5.3').Name | Should -Match 'Global Administrator.*Conditional Access'
        }
        It 'builds admin accounts from settings with the mspadmin prefix on the onmicrosoft domain' {
            $inv = ($script:Plan | Where-Object Id -eq '5.4').Invocations[0]
            $inv.UpnPrefix | Should -Be 'mspadmin'
            $inv.Domain | Should -Be 'contoso.onmicrosoft.com'
        }
        It 'pins the break-glass account to the configured onmicrosoft domain' {
            ($script:Plan | Where-Object Id -eq '5.3').Invocations[0].Domain | Should -Be 'contoso.onmicrosoft.com'
        }
        It 'uses the onmicrosoft domain, not the GUID, for Exchange delegated sessions' {
            foreach ($s in $script:Plan | Where-Object { $_.Kind -ne 'Manual' -and $_.Phase -eq 'Tenant' }) {
                foreach ($inv in $s.Invocations | Where-Object { $_.Contains('Organization') }) {
                    $inv.Organization | Should -Be 'contoso.onmicrosoft.com' -Because "$($s.Id)"
                }
            }
        }
        It 'every automated step points at a script that exists in the repo' {
            foreach ($s in $script:Plan | Where-Object { $_.Kind -ne 'Manual' }) {
                (Join-Path $script:RepoRoot $s.Script) | Should -Exist -Because "$($s.Id) $($s.Name)"
            }
        }
        It 'every automated step has at least one invocation when it applies' {
            foreach ($s in $script:Plan | Where-Object { $_.Kind -ne 'Manual' -and $_.Applies }) {
                $s.Invocations.Count | Should -BeGreaterThan 0 -Because "$($s.Id) $($s.Name)"
            }
        }
        It 'every invocation only uses parameters the target script declares' {
            foreach ($s in $script:Plan | Where-Object { $_.Kind -ne 'Manual' }) {
                $cmd = Get-Command (Join-Path $script:RepoRoot $s.Script)
                foreach ($inv in $s.Invocations) {
                    foreach ($key in $inv.Keys) { $cmd.Parameters.Keys | Should -Contain $key -Because "$($s.Id) passes -$key to $($s.Script)" }
                }
            }
        }
        It 'leaves organization SOP links blank until configured' {
            foreach ($s in $script:Plan) { $s.SopUrl | Should -BeNullOrEmpty }
        }
        It 'uses configured SOP links for their respective phases' {
            $settings = $script:Settings.PSObject.Copy()
            $settings.onboarding = [pscustomobject]@{
                internalSopUrl = 'https://docs.msp.example/internal'
                tenantSopUrl = 'https://docs.msp.example/tenant'
            }
            $plan = Get-OnboardingPlan -Client $script:Client -Settings $settings
            foreach ($s in $plan) {
                $expected = if ($s.Phase -eq 'Internal') { $settings.onboarding.internalSopUrl } else { $settings.onboarding.tenantSopUrl }
                $s.SopUrl | Should -Be $expected
            }
        }
        It 'supports existing settings without the optional onboarding links' {
            $settings = $script:Settings.PSObject.Copy()
            $settings.PSObject.Properties.Remove('onboarding')
            foreach ($s in (Get-OnboardingPlan -Client $script:Client -Settings $settings)) {
                $s.SopUrl | Should -BeNullOrEmpty
            }
        }
        It 'skips the ironScales mailbox and American HelpDesk when the client has neither' {
            ($script:Plan | Where-Object Id -eq '5.13').Applies | Should -BeFalse
            ($script:Plan | Where-Object Id -eq '5.8').Applies | Should -BeFalse
        }
        It 'uses the client alias as the hidden contact and IT@ member by default' {
            ($script:Plan | Where-Object Id -eq '5.10').Invocations[0].ExternalEmailAddress | Should -Be 'contoso.clients@msp.example'
            ($script:Plan | Where-Object Id -eq '5.11').Invocations[0].Members | Should -Be @('contoso.clients@msp.example')
            ($script:Plan | Where-Object Id -eq '5.11').Invocations[0].PrimarySmtpAddress | Should -Be 'IT@contosodental.example'
        }
        It 'creates the support contact before the alerts list that needs it' {
            $ids = $script:Plan.Id
            $ids.IndexOf('5.12a') | Should -BeLessThan $ids.IndexOf('5.12b')
            ($script:Plan | Where-Object Id -eq '5.12b').Invocations[0].Members | Should -Be @('support@msp.example')
        }
        It 'fans out one invocation per domain for SPF and DKIM' {
            $multi = $script:Client.PSObject.Copy()
            $multi.domains = @('contosodental.example', 'contoso-smiles.com')
            $plan = Get-OnboardingPlan -Client $multi -Settings $script:Settings
            ($plan | Where-Object Id -eq '5.5').Invocations.Count | Should -Be 2
            ($plan | Where-Object Id -eq '5.6').Invocations.Count | Should -Be 2
        }
        It 'fans out one invocation per POC and marks 1.11 not applicable without POCs' {
            ($script:Plan | Where-Object Id -eq '1.11a').Invocations.Count | Should -Be 1
            $noPoc = $script:Client.PSObject.Copy(); $noPoc.poc = @()
            $plan = Get-OnboardingPlan -Client $noPoc -Settings $script:Settings
            ($plan | Where-Object Id -eq '1.11a').Applies | Should -BeFalse
        }
        It 'honors contactAddress override' {
            $c = $script:Client.PSObject.Copy()
            $c | Add-Member -NotePropertyName contactAddress -NotePropertyValue 'clients@msp.example' -Force
            $plan = Get-OnboardingPlan -Client $c -Settings $script:Settings
            ($plan | Where-Object Id -eq '5.10').Invocations[0].ExternalEmailAddress | Should -Be 'clients@msp.example'
            ($plan | Where-Object Id -eq '5.11').Invocations[0].Members | Should -Be @('clients@msp.example')
        }
        It 'filters by phase' {
            $tenantOnly = Get-OnboardingPlan -Client $script:Client -Settings $script:Settings -Phase Tenant
            ($tenantOnly.Phase | Select-Object -Unique) | Should -Be 'Tenant'
        }
    }

    Context 'Get-OnboardingGraphScopes' {
        It 'covers the tenant-phase writes' {
            $s = Get-OnboardingGraphScopes -Phase Tenant
            $s | Should -Contain 'User.ReadWrite.All'
            $s | Should -Contain 'Policy.ReadWrite.ConditionalAccess'
            $s | Should -Contain 'RoleManagement.ReadWrite.Directory'
        }
    }

    Context 'Save-OnboardingRunRecord' {
        It 'writes a JSON record without secrets' {
            $results = @([pscustomobject]@{ Id = '5.3'; Name = 'bg'; Phase = 'Tenant'; Kind = 'Auto'; Status = 'Done'; Detail = 'UserPrincipalName=x Created=True'; StartedAt = (Get-Date).ToString('o') })
            $file = Save-OnboardingRunRecord -Client $script:Client -Results $results -RunsPath (Join-Path $TestDrive 'runs')
            $file | Should -Exist
            $record = Get-Content $file -Raw | ConvertFrom-Json
            $record.shortName | Should -Be 'contoso'
            $record.steps.Count | Should -Be 1
            (Get-Content $file -Raw) | Should -Not -Match 'Password'
        }
    }
}
