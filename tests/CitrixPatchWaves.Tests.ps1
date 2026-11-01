[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with the It blocks.')]
param()

BeforeAll {
    # A stub lets the module resolve the Citrix command on a machine without the
    # SDK; Pester mocks provide every result.
    function global:Get-BrokerMachine { [CmdletBinding()] param([string]$AdminAddress, [int]$MaxRecordCount) [void]$AdminAddress; [void]$MaxRecordCount }

    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repositoryRoot 'src/CitrixPatchWaves/CitrixPatchWaves.psd1') -Force
    $samplePath = Join-Path $repositoryRoot 'samples/lisbon-october.maintenance.json'

    # A fresh, editable copy of the sample definition for each test.
    function Get-TestDefinition { Get-Content $samplePath -Raw | ConvertFrom-Json -AsHashtable }

    function Invoke-TestRun {
        param([hashtable]$Failure = @{}, [scriptblock]$Change)
        $definition = Get-TestDefinition
        if ($Change) { & $Change $definition }
        $maintenance = Import-CpwMaintenance -InputObject $definition
        $provider = New-CpwSimulationProvider -StartTime $maintenance.WindowStart -Failure $Failure
        Invoke-CpwMaintenance -Maintenance $maintenance -Provider $provider
    }

    function Get-Machine { param($Run, [string]$Name) $Run.machines | Where-Object name -EQ $Name }
}

Describe 'Module' {
    It 'has a valid manifest at version 0.1.0' {
        (Test-ModuleManifest (Join-Path $repositoryRoot 'src/CitrixPatchWaves/CitrixPatchWaves.psd1')).Version | Should -Be '0.1.0'
    }
}

Describe 'Test-CpwMaintenance' {
    It 'accepts the sample' {
        @(Get-TestDefinition | Test-CpwMaintenance) | Should -HaveCount 0
    }

    It 'reports <Path> when <Case>' -ForEach @(
        @{ Case = 'the schema version is wrong'; Path = 'schemaVersion'; Change = { param($d) $d.schemaVersion = 2 } }
        @{ Case = 'the window has no offset'; Path = 'window.start'; Change = { param($d) $d.window.start = '2026-10-04T21:00:00' } }
        @{ Case = 'the window ends before it starts'; Path = 'window.end'; Change = { param($d) $d.window.end = '2026-10-04T20:00:00Z' } }
        @{ Case = 'the window is longer than 72 hours'; Path = 'window.end'; Change = { param($d) $d.window.end = '2026-10-08T21:00:00Z' } }
        @{ Case = 'nothing is targeted'; Path = 'target'; Change = { param($d) $d.target.deliveryGroups = @() } }
        @{ Case = 'a machine name is invalid'; Path = 'target.exclude[0]'; Change = { param($d) $d.target.exclude = @('bad name') } }
        @{ Case = 'the budget is not below the wave size'; Path = 'waves.failureBudget'; Change = { param($d) $d.waves.failureBudget = 10 } }
        @{ Case = 'a number is not whole'; Path = 'waves.concurrency'; Change = { param($d) $d.waves.concurrency = 2.5 } }
        @{ Case = 'the message has no text'; Path = 'drain.message.text'; Change = { param($d) $d.drain.message.text = '' } }
        @{ Case = 'the update category is unknown'; Path = 'patch.windowsUpdates.categories[0]'; Change = { param($d) $d.patch.windowsUpdates.categories = @('Drivers') } }
        @{ Case = 'an application is listed twice'; Path = 'patch.software[1].wingetId'; Change = { param($d) $d.patch.software[1].wingetId = 'google.chrome' } }
        @{ Case = 'there is nothing to patch'; Path = 'patch'; Change = { param($d) $d.patch.windowsUpdates.enabled = $false; $d.patch.software = @() } }
        @{ Case = 'the reboot timeout is too short'; Path = 'reboot.timeoutMinutes'; Change = { param($d) $d.reboot.timeoutMinutes = 1 } }
        @{ Case = 'a service name is invalid'; Path = 'verify.services[0]'; Change = { param($d) $d.verify.services = @('Broker Agent') } }
    ) {
        $definition = Get-TestDefinition
        & $Change $definition
        @(Test-CpwMaintenance -InputObject $definition).Path | Should -Contain $Path
    }

    It 'rejects something that is not an object' {
        @(Test-CpwMaintenance -InputObject 'text').Message | Should -Contain 'The maintenance definition must be a JSON object.'
    }
}

Describe 'Import-CpwMaintenance' {
    It 'fills in the defaults' {
        $maintenance = Import-CpwMaintenance -InputObject @{
            schemaVersion = 1; name = 'Minimal'; window = @{ start = '2026-10-04T21:00:00Z'; end = '2026-10-05T01:00:00+01:00' }
            target = @{ deliveryGroups = @('DG-LIS-W11-DED-FINANCE') }
        }
        $maintenance.WindowEnd | Should -Be ([DateTimeOffset]::new(2026, 10, 5, 0, 0, 0, [TimeSpan]::Zero))
        $maintenance.CanarySize | Should -Be 1
        $maintenance.WaveSize | Should -Be 10
        $maintenance.Concurrency | Should -Be 5
        $maintenance.FailureBudget | Should -Be 0
        $maintenance.DrainTimeoutMinutes | Should -Be 60
        $maintenance.ForceLogoff | Should -BeFalse
        $maintenance.WindowsUpdates | Should -BeTrue
        $maintenance.UpdateCategories | Should -Be @('Security Updates', 'Critical Updates')
        $maintenance.Services | Should -Be @('BrokerAgent')
        $maintenance.DeliveryGroups | Should -Be @('DG-LIS-W11-DED-FINANCE')
    }

    It 'normalizes machine names' {
        $definition = Get-TestDefinition
        $definition.target.exclude = @('corp\lisw11fin011', 'LISW11FIN012.corp.example.test')
        (Import-CpwMaintenance -InputObject $definition).Exclude | Should -Be @('LISW11FIN011', 'LISW11FIN012')
    }

    It 'throws with every problem' {
        $definition = Get-TestDefinition
        $definition.name = ''
        $definition.waves.canarySize = -1
        { Import-CpwMaintenance -InputObject $definition } | Should -Throw '*name:*canarySize*'
    }

    It 'reports a missing file and invalid JSON' {
        { Import-CpwMaintenance -Path (Join-Path $TestDrive 'missing.json') } | Should -Throw 'Maintenance file not found*'
        Set-Content (Join-Path $TestDrive 'bad.json') '{ nope'
        { Import-CpwMaintenance -Path (Join-Path $TestDrive 'bad.json') } | Should -Throw 'The maintenance file is not valid JSON*'
    }
}

Describe 'Get-CpwPlan' {
    BeforeAll {
        $maintenance = Import-CpwMaintenance -Path $samplePath
        $plan = Get-CpwPlan -Maintenance $maintenance -Provider (New-CpwSimulationProvider)
    }

    It 'leaves out excluded, busy, and unregistered machines with the reason' {
        $reasons = @{}
        foreach ($entry in $plan.exclusions) { $reasons[$entry.name] = $entry.reason }
        $reasons.Keys | Sort-Object | Should -Be @('LISW11FIN011', 'LISW11FIN019', 'LISW11FIN022')
        $reasons.LISW11FIN011 | Should -BeLike 'Excluded in the maintenance file*'
        $reasons.LISW11FIN019 | Should -BeLike 'Already in maintenance mode*'
        $reasons.LISW11FIN022 | Should -BeLike 'Not registered before the change (Unregistered, power Off)*'
    }

    It 'takes the canary from each delivery group in turn and gives it no budget' {
        $plan.waves[0].kind | Should -Be 'Canary'
        $plan.waves[0].failureBudget | Should -Be 0
        $plan.waves[0].machines | Should -Be @('LISW11FIN001', 'LISW11ENG001')
    }

    It 'splits the rest into waves of the configured size in delivery group order' {
        @($plan.waves | ForEach-Object { $_.machines.Count }) | Should -Be @(2, 10, 10, 10, 1)
        $plan.waves[1].machines[0] | Should -Be 'LISW11FIN002'
        $plan.waves[3].machines[0] | Should -Be 'LISW11ENG002'
        @($plan.waves | Select-Object -Skip 1 | ForEach-Object failureBudget | Sort-Object -Unique) | Should -Be @(1)
        $plan.machines.Count | Should -Be 33
    }

    It 'leaves out pooled MCS machines and warns about unknown targets' {
        $definition = Get-TestDefinition
        $definition.target.deliveryGroups = @('DG-LIS-W11-POOL-SUPPORT', 'DG-LIS-W11-UNKNOWN')
        $definition.target.include = @('LISW11FIN001', 'LISW11XXX001')
        $result = Get-CpwPlan -Maintenance (Import-CpwMaintenance -InputObject $definition) -Provider (New-CpwSimulationProvider)
        @($result.exclusions | Where-Object { $_.reason -like 'Pooled MCS desktop*' }) | Should -HaveCount 8
        $result.machines.name | Should -Be @('LISW11FIN001')
        $result.warnings | Should -Contain 'LISW11XXX001 is in target.include but was not found in the site.'
        $result.warnings | Should -Contain 'Delivery group DG-LIS-W11-UNKNOWN has no machines in the site.'
    }

    It 'changes nothing' {
        $provider = New-CpwSimulationProvider
        $null = Get-CpwPlan -Maintenance $maintenance -Provider $provider
        @($provider.State.Machines.Values | Where-Object InMaintenanceMode).Name | Should -Be @('LISW11FIN019')
    }
}

Describe 'Invoke-CpwMaintenance' {
    Context 'a regular night' {
        BeforeAll { $run = Invoke-TestRun }

        It 'patches every drained machine and returns it to service' {
            $run.outcome | Should -Be 'CompletedWithExceptions'
            $run.totals.completed | Should -Be 30
            $run.totals.leftInMaintenance | Should -Be 0
            @($run.waves.result | Sort-Object -Unique) | Should -Be @('Passed')
        }

        It 'returns machines whose sessions outlast the drain to service unpatched' {
            $machine = Get-Machine $run 'LISW11FIN008'
            $machine.state | Should -Be 'NotDrained'
            $machine.inMaintenanceMode | Should -BeFalse
            $machine.patchStartedAt | Should -BeNullOrEmpty
            $machine.detail | Should -BeLike '*still active after 60 minutes*'
        }

        It 'messages only machines with sessions' {
            (Get-Machine $run 'LISW11FIN001').messageSent | Should -Be ((Get-Machine $run 'LISW11FIN001').sessionsAtDrain -gt 0)
            @($run.machines | Where-Object { $_.messageSent -and $_.sessionsAtDrain -eq 0 }) | Should -HaveCount 0
            @($run.machines | Where-Object messageSent).Count | Should -BeGreaterThan 0
        }

        It 'records what was installed' {
            (Get-Machine $run 'LISW11FIN001').installed | Should -Contain '2026-10 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5990117)'
        }

        It 'never patches more machines at once than the concurrency allows' {
            $active = @{}
            $peak = 0
            foreach ($entry in $run.events) {
                if ($entry.step -eq 'PatchStarted') { $active[$entry.machine] = $true }
                if ($entry.step -in 'Completed', 'Failed') { $active.Remove($entry.machine) }
                $peak = [Math]::Max($peak, $active.Count)
            }
            $peak | Should -Be 5
        }

        It 'starts each wave only after the previous one finished, inside the window' {
            for ($index = 1; $index -lt $run.waves.Count; $index++) {
                [DateTimeOffset]$run.waves[$index].startedAt | Should -BeGreaterOrEqual ([DateTimeOffset]$run.waves[$index - 1].finishedAt)
            }
            [DateTimeOffset]$run.finishedAt | Should -BeLessOrEqual ([DateTimeOffset]$run.maintenance.windowEnd)
        }

        It 'is deterministic' {
            ((Invoke-TestRun) | ConvertTo-Json -Depth 12) | Should -BeExactly ($run | ConvertTo-Json -Depth 12)
        }
    }

    It 'stops after the canary when one canary machine fails and keeps it in maintenance mode' {
        $run = Invoke-TestRun -Failure @{ LISW11FIN001 = 'PatchFails' }
        $run.outcome | Should -Be 'Stopped'
        $run.stopReason | Should -BeLike 'The canary wave had 1 failed machine(s) (LISW11FIN001)*'
        (Get-Machine $run 'LISW11FIN001').inMaintenanceMode | Should -BeTrue
        (Get-Machine $run 'LISW11ENG001').state | Should -Be 'Completed'
        @($run.waves | Select-Object -Skip 1 | ForEach-Object result | Sort-Object -Unique) | Should -Be @('NotStarted')
        $run.totals.notStarted | Should -Be 31
    }

    It 'keeps going when a wave stays within its budget' {
        $run = Invoke-TestRun -Failure @{ LISW11FIN003 = 'UpdatesRemain' }
        $run.waves[1].result | Should -Be 'Passed'
        $run.waves[1].failed | Should -Be 1
        (Get-Machine $run 'LISW11FIN003').detail | Should -Be '1 requested update(s) still applicable after the restart.'
        $run.waves[4].result | Should -Be 'Passed'
    }

    It 'stops when a wave goes over its budget' {
        $run = Invoke-TestRun -Failure @{ LISW11FIN003 = 'PatchFails'; LISW11FIN006 = 'NoRegistration' }
        $run.waves[1].result | Should -Be 'Stopped'
        (Get-Machine $run 'LISW11FIN006').detail | Should -BeLike 'Did not register with the Delivery Controller within 30 minutes*'
        $run.totals.leftInMaintenance | Should -Be 2
        $run.waves[2].result | Should -Be 'NotStarted'
    }

    It 'fails a machine whose required service is not running' {
        $run = Invoke-TestRun -Failure @{ LISW11ENG001 = 'ServiceStopped' }
        (Get-Machine $run 'LISW11ENG001').detail | Should -Be 'Registered, but BrokerAgent is Stopped after the restart.'
    }

    It 'fails a machine that still has a requested update after the restart' {
        $run = Invoke-TestRun -Failure @{ LISW11ENG002 = 'UpdatesRemain' }
        $machine = Get-Machine $run 'LISW11ENG002'
        $machine.state | Should -Be 'Failed'
        $machine.inMaintenanceMode | Should -BeTrue
        $machine.detail | Should -Be '1 requested update(s) still applicable after the restart.'
    }

    It 'does not ask for applicable updates when Windows Update is off' {
        $run = Invoke-TestRun -Failure @{ LISW11ENG002 = 'UpdatesRemain' } -Change { param($d) $d.patch.windowsUpdates.enabled = $false }
        (Get-Machine $run 'LISW11ENG002').state | Should -Be 'Completed'
    }

    It 'logs off remaining sessions only when forceLogoff is on' {
        $run = Invoke-TestRun -Failure @{ LISW11FIN002 = 'SessionsNeverEnd' } -Change { param($d) $d.drain.forceLogoff = $true }
        $machine = Get-Machine $run 'LISW11FIN002'
        $machine.forcedLogoff | Should -BeTrue
        $machine.state | Should -Be 'Completed'
        $run.totals.notDrained | Should -Be 0
    }

    It 'returns a machine to service when sessions survive a forced logoff' {
        $run = Invoke-TestRun -Failure @{ LISW11FIN002 = 'LogoffFails' } -Change { param($d) $d.drain.forceLogoff = $true }
        $machine = Get-Machine $run 'LISW11FIN002'
        $machine.state | Should -Be 'NotDrained'
        $machine.inMaintenanceMode | Should -BeFalse
        $machine.detail | Should -Be '1 session(s) still active 10 minutes after a forced logoff; returned to service unpatched.'
        @($run.events | Where-Object { $_.machine -eq 'LISW11FIN002' -and $_.step -eq 'ForcedLogoff' }) | Should -HaveCount 1
        $run.outcome | Should -Be 'CompletedWithExceptions'
    }

    It 'defers the waves that do not fit in the window' {
        $run = Invoke-TestRun -Change { param($d) $d.window.end = '2026-10-05T00:00:00Z' }
        $run.outcome | Should -Be 'WindowClosed'
        $run.waves[-1].result | Should -Be 'Deferred'
        @($run.machines | Where-Object state -EQ 'Deferred' | Where-Object inMaintenanceMode) | Should -HaveCount 0
        @($run.events | Where-Object { $_.step -eq 'PatchStarted' -and [DateTimeOffset]$_.time -ge [DateTimeOffset]'2026-10-05T00:00:00Z' }) | Should -HaveCount 0
    }

    It 'writes a journal line for every event' {
        $maintenance = Import-CpwMaintenance -Path $samplePath
        $journal = Join-Path $TestDrive 'out/journal.jsonl'
        $run = Invoke-CpwMaintenance -Maintenance $maintenance -Provider (New-CpwSimulationProvider) -JournalPath $journal
        @(Get-Content $journal).Count | Should -Be $run.events.Count
        (Get-Content $journal -TotalCount 1 | ConvertFrom-Json).step | Should -Be 'Started'
    }

    It 'refuses to start before the window' {
        $maintenance = Import-CpwMaintenance -Path $samplePath
        $provider = New-CpwSimulationProvider -StartTime $maintenance.WindowStart.AddHours(-1)
        { Invoke-CpwMaintenance -Maintenance $maintenance -Provider $provider } | Should -Throw 'The maintenance window starts at 2026-10-04T21:00:00Z*'
    }

    It 'rejects unknown failures and machines in the simulation' {
        { New-CpwSimulationProvider -Failure @{ LISW11FIN001 = 'Meteor' } } | Should -Throw "Unknown failure 'Meteor'*"
        { New-CpwSimulationProvider -Failure @{ NOPE001 = 'PatchFails' } } | Should -Throw '*no machine named NOPE001*'
    }
}

Describe 'Citrix provider' {
    BeforeAll {
        Mock -ModuleName CitrixPatchWaves Get-BrokerMachine {
            [pscustomobject]@{ MachineName = 'CORP\LISW11FIN001'; DNSName = 'lisw11fin001.corp.example.test'; DesktopGroupName = 'DG-LIS-W11-DED-FINANCE'; CatalogName = 'MC-LIS-W11-DED-FINANCE'; ProvisioningType = 'MCS'; AllocationType = 'Static'; SessionSupport = 'SingleSession'; InMaintenanceMode = $false; RegistrationState = 'Registered'; PowerState = 'On'; SessionCount = 1 }
            [pscustomobject]@{ MachineName = 'CORP\LISW11FIN002'; DNSName = 'lisw11fin002.corp.example.test'; DesktopGroupName = 'DG-LIS-W11-DED-FINANCE'; CatalogName = 'MC-LIS-W11-DED-FINANCE'; ProvisioningType = 'PVS'; AllocationType = 'Static'; SessionSupport = 'SingleSession'; InMaintenanceMode = $false; RegistrationState = 'Registered'; PowerState = 'On'; SessionCount = 0 }
        }
        $maintenance = Import-CpwMaintenance -Path $samplePath
        $provider = New-CpwCitrixProvider -AdminAddress 'ddc01.corp.example.test'
    }

    It 'plans against the site read-only' {
        $plan = Get-CpwPlan -Maintenance $maintenance -Provider $provider
        $plan.machines.name | Should -Be @('LISW11FIN001')
        $plan.exclusions[0].reason | Should -Be 'Streamed by PVS: update the vDisk instead.'
        $plan.simulation | Should -BeFalse
        Should -Invoke -ModuleName CitrixPatchWaves Get-BrokerMachine -ParameterFilter { $AdminAddress -eq 'ddc01.corp.example.test' }
    }

    It 'does nothing without -Execute' {
        { Invoke-CpwMaintenance -Maintenance $maintenance -Provider $provider } | Should -Throw 'Nothing was changed*'
    }

    It 'does not change a real site in this version' {
        # A window that has already started, so the engine reaches the first action.
        $definition = Get-TestDefinition
        $definition.window.start = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
        $definition.window.end = [DateTimeOffset]::UtcNow.AddHours(5).ToString('o')
        $open = Import-CpwMaintenance -InputObject $definition
        { Invoke-CpwMaintenance -Maintenance $open -Provider $provider -Execute } | Should -Throw '*does not change it*'
    }
}

Describe 'Export-CpwChangeRecord' {
    It 'writes JSON, Markdown, and HTML with every value escaped' {
        $run = Invoke-TestRun -Failure @{ LISW11FIN001 = 'PatchFails' } -Change { param($d) $d.name = 'Night <script>alert(1)</script> | test' }
        $files = Export-CpwChangeRecord -Run $run -OutputDirectory (Join-Path $TestDrive 'record')
        $files.Name | Should -Be @('run.json', 'change-record.md', 'change-record.html')
        $html = Get-Content (Join-Path $TestDrive 'record/change-record.html') -Raw
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;'
        $markdown = Get-Content (Join-Path $TestDrive 'record/change-record.md') -Raw
        $markdown | Should -Match '\*\*Stopped: 1 of 33 machines patched\. The canary wave had 1 failed machine'
        $markdown | Should -Match '\| LISW11FIN001 \| Failed \| Yes \|'
        (Get-Content (Join-Path $TestDrive 'record/run.json') -Raw | ConvertFrom-Json).outcome | Should -Be 'Stopped'
    }
}

Describe 'Invoke-PatchWaves.ps1' {
    It 'runs the <Scenario> scenario to <Outcome>' -ForEach @(
        @{ Scenario = 'normal'; Outcome = 'CompletedWithExceptions' }
        @{ Scenario = 'canary-failure'; Outcome = 'Stopped' }
        @{ Scenario = 'wave-over-budget'; Outcome = 'Stopped' }
        @{ Scenario = 'window-closes'; Outcome = 'WindowClosed' }
        @{ Scenario = 'force-logoff'; Outcome = 'Completed' }
    ) {
        $output = Join-Path $TestDrive $Scenario
        $summary = & (Join-Path $repositoryRoot 'scripts/Invoke-PatchWaves.ps1') -Simulation -Scenario $Scenario -OutputDirectory $output
        $summary.Outcome | Should -Be $Outcome
        Test-Path (Join-Path $output 'change-record.html') | Should -BeTrue
        Test-Path (Join-Path $output 'journal.jsonl') | Should -BeTrue
    }

    It 'writes only a plan with -PlanOnly' {
        $output = Join-Path $TestDrive 'plan'
        $waves = & (Join-Path $repositoryRoot 'scripts/Invoke-PatchWaves.ps1') -Simulation -PlanOnly -OutputDirectory $output 3>$null 6>$null
        @($waves).Count | Should -Be 5
        (Get-ChildItem $output).Name | Should -Be @('plan.json')
    }

    It 'refuses to change a real site' {
        { & (Join-Path $repositoryRoot 'scripts/Invoke-PatchWaves.ps1') -AdminAddress 'ddc01' -OutputDirectory (Join-Path $TestDrive 'site') } | Should -Throw '*Add -PlanOnly*'
    }
}

Describe 'Demo data' {
    It 'matches what the engine produces today (run scripts/Update-DemoData.ps1)' {
        $generated = Join-Path $TestDrive 'data'
        & (Join-Path $repositoryRoot 'scripts/Update-DemoData.ps1') -OutputDirectory $generated | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'site/data') -Filter *.json) {
            $expected = (Get-Content -LiteralPath $file.FullName -Raw) -replace "`r`n", "`n"
            $actual = (Get-Content -LiteralPath (Join-Path $generated $file.Name) -Raw) -replace "`r`n", "`n"
            $actual | Should -BeExactly $expected -Because "$($file.Name) is stale"
        }
    }
}
