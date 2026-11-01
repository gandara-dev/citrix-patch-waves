[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with the It blocks.')]
param()

BeforeAll {
    # Stubs let the module resolve the Citrix commands on a machine without the
    # SDK; Pester mocks provide every result.
    function global:Get-BrokerMachine { [CmdletBinding()] param([string]$AdminAddress, [int]$MaxRecordCount, [string]$MachineName) [void]$AdminAddress; [void]$MaxRecordCount; [void]$MachineName }
    function global:Get-BrokerSession { [CmdletBinding()] param([string]$AdminAddress, [string]$MachineName, [int]$MaxRecordCount) [void]$AdminAddress; [void]$MachineName; [void]$MaxRecordCount }
    function global:Set-BrokerMachineMaintenanceMode { [CmdletBinding()] param([string]$AdminAddress, [object[]]$InputObject, [bool]$MaintenanceMode) [void]$AdminAddress; [void]$InputObject; [void]$MaintenanceMode }
    function global:Send-BrokerSessionMessage { [CmdletBinding()] param([string]$AdminAddress, [object[]]$InputObject, [string]$MessageStyle, [string]$Title, [string]$Text) [void]$AdminAddress; [void]$InputObject; [void]$MessageStyle; [void]$Title; [void]$Text }
    function global:Stop-BrokerSession { [CmdletBinding()] param([string]$AdminAddress, [object[]]$InputObject) [void]$AdminAddress; [void]$InputObject }
    function global:New-BrokerHostingPowerAction { [CmdletBinding()] param([string]$AdminAddress, [string]$MachineName, [string]$Action) [void]$AdminAddress; [void]$MachineName; [void]$Action }

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
    It 'has a valid manifest at version 0.2.0' {
        (Test-ModuleManifest (Join-Path $repositoryRoot 'src/CitrixPatchWaves/CitrixPatchWaves.psd1')).Version | Should -Be '0.2.0'
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
        @{ Case = 'the reboot timeout is too short'; Path = 'reboot.timeoutMinutes'; Change = { param($d) $d.reboot.timeoutMinutes = 1 } }
        @{ Case = 'a service name is invalid'; Path = 'verify.services[0]'; Change = { param($d) $d.verify.services = @('Broker Agent') } }
    ) {
        $definition = Get-TestDefinition
        & $Change $definition
        @(Test-CpwMaintenance -InputObject $definition).Path | Should -Contain $Path
    }

    It 'accepts a restart-only change' {
        $definition = Get-TestDefinition
        $definition.patch.windowsUpdates.enabled = $false
        $definition.patch.software = @()
        @(Test-CpwMaintenance -InputObject $definition) | Should -HaveCount 0
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

    It 'restarts without patching when there is nothing to install' {
        $run = Invoke-TestRun -Change { param($d) $d.patch.windowsUpdates.enabled = $false; $d.patch.software = @() }
        $run.outcome | Should -Be 'CompletedWithExceptions'
        $run.totals.completed | Should -Be 30
        @($run.events | Where-Object step -In 'PatchStarted', 'Patched') | Should -HaveCount 0
        @($run.machines | Where-Object state -EQ 'Completed' | Where-Object { $_.restartedAt -and -not $_.patchStartedAt }) | Should -HaveCount 30
    }

    It 'fails only the machine whose provider call throws and keeps it in maintenance mode' {
        $definition = Get-TestDefinition
        $maintenance = Import-CpwMaintenance -InputObject $definition
        $provider = New-CpwSimulationProvider -StartTime $maintenance.WindowStart
        $restart = $provider.StartRestart
        $provider.StartRestart = {
            param($State, [string]$Name)
            if ($Name -eq 'LISW11FIN004') { throw 'The hypervisor did not accept the power action.' }
            & $restart $State $Name
        }.GetNewClosure()
        $run = Invoke-CpwMaintenance -Maintenance $maintenance -Provider $provider
        $machine = Get-Machine $run 'LISW11FIN004'
        $machine.state | Should -Be 'Failed'
        $machine.inMaintenanceMode | Should -BeTrue
        $machine.detail | Should -Be 'The provider failed while the machine was Restarting: The hypervisor did not accept the power action.'
        $run.totals.completed | Should -BeGreaterThan 20
    }

    It 'rejects unknown failures and machines in the simulation' {
        { New-CpwSimulationProvider -Failure @{ LISW11FIN001 = 'Meteor' } } | Should -Throw "Unknown failure 'Meteor'*"
        { New-CpwSimulationProvider -Failure @{ NOPE001 = 'PatchFails' } } | Should -Throw '*no machine named NOPE001*'
    }
}

Describe 'Citrix provider' {
    BeforeAll {
        # A two-machine fake site behind mocks of the Broker SDK and WinRM:
        # LISW11FIN001 is an MCS desktop on a hosting connection with one
        # session; LISW11ENG001 is a Remote PC Access machine with none.
        # LISW11FIN002 is streamed by PVS and is left out of every plan.
        function Initialize-TestSite {
            $script:site = @{
                'CORP\LISW11FIN001' = @{ Group = 'DG-LIS-W11-DED-FINANCE'; Provisioning = 'MCS'; Hosting = 'HC-LIS-VSPHERE'; Sessions = 1; Maintenance = $false; Restarted = $false; Polls = 0 }
                'CORP\LISW11FIN002' = @{ Group = 'DG-LIS-W11-DED-FINANCE'; Provisioning = 'PVS'; Hosting = 'HC-LIS-VSPHERE'; Sessions = 0; Maintenance = $false; Restarted = $false; Polls = 0 }
                'CORP\LISW11ENG001' = @{ Group = 'DG-LIS-W11-RPC-ENGINEERING'; Provisioning = 'Manual'; Hosting = $null; Sessions = 0; Maintenance = $false; Restarted = $false; Polls = 0 }
            }
        }
        function Get-TestSiteMachine {
            param([string]$Name)
            $machine = $script:site[$Name]
            # A restarted machine is unregistered on the first poll after the
            # restart and registered again on the next one.
            $registration = 'Registered'
            if ($machine.Restarted -and $machine.Polls++ -eq 0) { $registration = 'Unregistered' }
            $short = ($Name -split '\\')[-1]
            [pscustomobject]@{
                MachineName = $Name; DNSName = "$($short.ToLowerInvariant()).corp.example.test"; DesktopGroupName = $machine.Group
                CatalogName = $machine.Group -replace '^DG-', 'MC-'; ProvisioningType = $machine.Provisioning; AllocationType = 'Static'
                SessionSupport = 'SingleSession'; InMaintenanceMode = $machine.Maintenance; RegistrationState = $registration; PowerState = 'On'
                SessionCount = $machine.Sessions; HypervisorConnectionName = $machine.Hosting; LastDeregistrationTime = $null
            }
        }
        function Get-RestartDefinition {
            $definition = Get-TestDefinition
            $definition.window.start = '2026-10-04T21:00:00Z'
            $definition.target.exclude = @()
            $definition.waves.canarySize = 1
            $definition.waves.waveSize = 2
            $definition.drain.timeoutMinutes = 0
            $definition.drain.forceLogoff = $true
            $definition.patch.windowsUpdates.enabled = $false
            $definition.patch.software = @()
            $definition
        }
        function Get-TestCitrixProvider {
            $provider = New-CpwCitrixProvider -AdminAddress 'ddc01.corp.example.test'
            # A virtual clock, so a test never sleeps.
            $provider.State.Clock = [DateTimeOffset]::new(2026, 10, 4, 21, 0, 0, [TimeSpan]::Zero)
            $provider.Now = { param($State) $State.Clock }
            $provider.Wait = { param($State, [int]$Minutes) $State.Clock = $State.Clock.AddMinutes($Minutes) }
            $provider
        }

        Mock -ModuleName CitrixPatchWaves Get-BrokerMachine { foreach ($name in @($script:site.Keys | Sort-Object)) { Get-TestSiteMachine $name } }
        Mock -ModuleName CitrixPatchWaves Get-BrokerMachine { Get-TestSiteMachine $MachineName } -ParameterFilter { $MachineName }
        Mock -ModuleName CitrixPatchWaves Get-BrokerSession {
            $machine = $script:site[$MachineName]
            for ($i = 1; $i -le $machine.Sessions; $i++) { [pscustomobject]@{ MachineName = $MachineName; Uid = $i } }
        }
        Mock -ModuleName CitrixPatchWaves Set-BrokerMachineMaintenanceMode { $script:site[[string]$InputObject[0]].Maintenance = $MaintenanceMode }
        Mock -ModuleName CitrixPatchWaves Send-BrokerSessionMessage { }
        Mock -ModuleName CitrixPatchWaves Stop-BrokerSession { $script:site[$InputObject[0].MachineName].Sessions = 0 }
        Mock -ModuleName CitrixPatchWaves New-BrokerHostingPowerAction { $script:site[$MachineName].Restarted = $true }
        Mock -ModuleName CitrixPatchWaves Invoke-Command {
            $name = 'CORP\' + ($ComputerName -split '\.')[0].ToUpperInvariant()
            $script:site[$name].Restarted = $true
        } -ParameterFilter { $ScriptBlock.ToString() -match 'shutdown\.exe' }
        Mock -ModuleName CitrixPatchWaves Invoke-Command {
            foreach ($service in $ArgumentList[0]) { [pscustomobject]@{ Name = $service; Status = 'Running' } }
        } -ParameterFilter { $ScriptBlock.ToString() -match 'Get-Service' }
    }

    BeforeEach { Initialize-TestSite }

    It 'plans against the site with Get-BrokerMachine' {
        $maintenance = Import-CpwMaintenance -Path $samplePath
        $plan = Get-CpwPlan -Maintenance $maintenance -Provider (New-CpwCitrixProvider -AdminAddress 'ddc01.corp.example.test')
        $plan.machines.name | Sort-Object | Should -Be @('LISW11ENG001', 'LISW11FIN001')
        $plan.exclusions[0].reason | Should -Be 'Streamed by PVS: update the vDisk instead.'
        $plan.simulation | Should -BeFalse
        Should -Invoke -ModuleName CitrixPatchWaves Get-BrokerMachine -ParameterFilter { $AdminAddress -eq 'ddc01.corp.example.test' }
    }

    It 'does nothing without -Execute' {
        $maintenance = Import-CpwMaintenance -InputObject (Get-RestartDefinition)
        { Invoke-CpwMaintenance -Maintenance $maintenance -Provider (Get-TestCitrixProvider) } | Should -Throw 'Nothing was changed*'
    }

    It 'refuses a change that installs updates before touching a machine' {
        $maintenance = Import-CpwMaintenance -Path $samplePath
        { Invoke-CpwMaintenance -Maintenance $maintenance -Provider (Get-TestCitrixProvider) -Execute } | Should -Throw '*cannot install updates in this version*'
        Should -Invoke -ModuleName CitrixPatchWaves Set-BrokerMachineMaintenanceMode -Times 0 -Exactly
    }

    It 'runs a restart-only change through the Broker SDK and WinRM' {
        $maintenance = Import-CpwMaintenance -InputObject (Get-RestartDefinition)
        $run = Invoke-CpwMaintenance -Maintenance $maintenance -Provider (Get-TestCitrixProvider) -Execute
        $run.outcome | Should -Be 'Completed'
        $run.simulation | Should -BeFalse
        $run.totals.completed | Should -Be 2
        $run.totals.leftInMaintenance | Should -Be 0
        $script:site['CORP\LISW11FIN001'].Maintenance | Should -BeFalse
        $script:site['CORP\LISW11ENG001'].Maintenance | Should -BeFalse
        (Get-Machine $run 'LISW11FIN001').forcedLogoff | Should -BeTrue

        Should -Invoke -ModuleName CitrixPatchWaves Set-BrokerMachineMaintenanceMode -Times 4 -Exactly
        Should -Invoke -ModuleName CitrixPatchWaves Send-BrokerSessionMessage -Times 1 -Exactly -ParameterFilter { $Title -eq 'Planned maintenance' -and $MessageStyle -eq 'Information' }
        Should -Invoke -ModuleName CitrixPatchWaves Stop-BrokerSession -Times 1 -Exactly
        Should -Invoke -ModuleName CitrixPatchWaves New-BrokerHostingPowerAction -Times 1 -Exactly -ParameterFilter { $MachineName -eq 'CORP\LISW11FIN001' -and $Action -eq 'Restart' }
        Should -Invoke -ModuleName CitrixPatchWaves Invoke-Command -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'lisw11eng001.corp.example.test' -and $ScriptBlock.ToString() -match 'shutdown\.exe' }
        Should -Invoke -ModuleName CitrixPatchWaves Invoke-Command -Times 2 -Exactly -ParameterFilter { $ScriptBlock.ToString() -match 'Get-Service' }
    }

    It 'does not count a machine as back until it was seen unregistered after the restart' {
        $provider = Get-TestCitrixProvider
        & $provider.GetMachines $provider.State | Out-Null
        & $provider.StartRestart $provider.State 'LISW11FIN001'
        # The controller has not noticed the restart yet.
        $script:site['CORP\LISW11FIN001'].Polls = 1
        & $provider.GetRegistration $provider.State 'LISW11FIN001' | Should -Be 'Restarting'
        $script:site['CORP\LISW11FIN001'].Polls = 0
        & $provider.GetRegistration $provider.State 'LISW11FIN001' | Should -Be 'Unregistered'
        & $provider.GetRegistration $provider.State 'LISW11FIN001' | Should -Be 'Registered'
    }

    It 'reports a service that is stopped or not installed' {
        Mock -ModuleName CitrixPatchWaves Invoke-Command {
            [pscustomobject]@{ Name = 'BrokerAgent'; Status = 'Stopped' }
            [pscustomobject]@{ Name = 'Spooler'; Status = 'NotInstalled' }
        } -ParameterFilter { $ScriptBlock.ToString() -match 'Get-Service' }
        $provider = Get-TestCitrixProvider
        & $provider.GetMachines $provider.State | Out-Null
        $status = & $provider.GetServiceStatus $provider.State 'LISW11ENG001' @('BrokerAgent', 'Spooler')
        $status['BrokerAgent'] | Should -Be 'Stopped'
        $status['Spooler'] | Should -Be 'NotInstalled'
    }

    It 'fails a machine whose restart is refused and keeps it in maintenance mode' {
        Mock -ModuleName CitrixPatchWaves New-BrokerHostingPowerAction { throw 'The hosting connection is in maintenance mode.' }
        $maintenance = Import-CpwMaintenance -InputObject (Get-RestartDefinition)
        $run = Invoke-CpwMaintenance -Maintenance $maintenance -Provider (Get-TestCitrixProvider) -Execute
        $machine = Get-Machine $run 'LISW11FIN001'
        $machine.state | Should -Be 'Failed'
        $machine.detail | Should -BeLike '*The hosting connection is in maintenance mode.'
        $script:site['CORP\LISW11FIN001'].Maintenance | Should -BeTrue
        $run.outcome | Should -Be 'Stopped'
        (Get-Machine $run 'LISW11ENG001').state | Should -Be 'NotStarted'
    }

    It 'refuses an action on a machine it did not plan' {
        $provider = Get-TestCitrixProvider
        { & $provider.SetMaintenance $provider.State 'LISW11XYZ001' $true } | Should -Throw '*was not read from the site*'
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

    It 'runs the weekly restart sample in the simulation' {
        $output = Join-Path $TestDrive 'weekly-restart'
        $sample = Join-Path $repositoryRoot 'samples/lisbon-weekly-restart.maintenance.json'
        $summary = & (Join-Path $repositoryRoot 'scripts/Invoke-PatchWaves.ps1') -Simulation -MaintenancePath $sample -OutputDirectory $output
        $summary.Patched + $summary.NotDrained | Should -Be 12
        $summary.Failed | Should -Be 0
        $run = Get-Content (Join-Path $output 'run.json') -Raw | ConvertFrom-Json
        @($run.events | Where-Object step -EQ 'PatchStarted') | Should -HaveCount 0
    }

    It 'writes only a plan with -PlanOnly' {
        $output = Join-Path $TestDrive 'plan'
        $waves = & (Join-Path $repositoryRoot 'scripts/Invoke-PatchWaves.ps1') -Simulation -PlanOnly -OutputDirectory $output 3>$null 6>$null
        @($waves).Count | Should -Be 5
        (Get-ChildItem $output).Name | Should -Be @('plan.json')
    }

    It 'asks for -PlanOnly or -Execute against a real site' {
        { & (Join-Path $repositoryRoot 'scripts/Invoke-PatchWaves.ps1') -AdminAddress 'ddc01' -OutputDirectory (Join-Path $TestDrive 'site') } | Should -Throw '*add -PlanOnly to review the plan or -Execute*'
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
