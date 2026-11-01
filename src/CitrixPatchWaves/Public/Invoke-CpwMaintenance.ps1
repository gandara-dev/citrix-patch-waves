$script:PatchTimeoutMinutes = 240
# How long sessions may take to end after a forced logoff before the machine
# goes back into service unpatched.
$script:LogoffGraceMinutes = 10
$script:TerminalStates = @('Completed', 'Failed', 'NotDrained', 'Deferred')

function Invoke-CpwMaintenance {
    <#
    .SYNOPSIS
    Runs the change: drain, patch, restart, and verify, one wave at a time.

    .DESCRIPTION
    For every wave the engine puts the machines in maintenance mode, waits for
    the sessions to end (sending the optional message), patches up to
    waves.concurrency machines at a time, restarts them, waits for them to
    register again, and checks the required services and that no requested
    update is still applicable.

    Healthy machines go back into service as soon as they pass. Failed
    machines stay in maintenance mode for investigation. Machines whose
    sessions do not end within drain.timeoutMinutes go back into service
    unpatched, unless drain.forceLogoff is true: then the sessions are logged
    off once, and a machine that still has sessions ten minutes later goes back
    into service unpatched. When a wave has more failed
    machines than its failure budget, no further wave starts. No wave and no
    machine starts patching after the window ends.

    Against a real site the change only runs with -Execute; the simulation
    always runs. This version's Citrix provider is read-only, so today only the
    simulation can run a change.

    .EXAMPLE
    $run = Invoke-CpwMaintenance -Maintenance $maintenance -Provider (New-CpwSimulationProvider -StartTime $maintenance.WindowStart)
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Maintenance,

        [Parameter(Mandatory)]
        [pscustomobject]$Provider,

        [System.Collections.IDictionary]$Plan,

        [switch]$Execute,

        [string]$JournalPath
    )

    if (-not $Provider.IsSimulation -and -not $Execute) {
        throw 'Nothing was changed: against a real site the change only runs with -Execute. Review the output of Get-CpwPlan first.'
    }
    if (-not $Plan) { $Plan = Get-CpwPlan -Maintenance $Maintenance -Provider $Provider }

    $state = $Provider.State
    $clock = { & $Provider.Now $state }
    $startedAt = & $clock
    if ($startedAt -lt $Maintenance.WindowStart) {
        throw "The maintenance window starts at $(Format-CpwDate $Maintenance.WindowStart); it is $(Format-CpwDate $startedAt)."
    }
    if ($JournalPath) {
        $journalDirectory = Split-Path -Parent $JournalPath
        if ($journalDirectory -and -not (Test-Path -LiteralPath $journalDirectory)) { New-Item -ItemType Directory -Path $journalDirectory -Force | Out-Null }
        Set-Content -LiteralPath $JournalPath -Value $null -Encoding utf8NoBOM
    }

    $events = [System.Collections.Generic.List[object]]::new()
    $log = {
        param([string]$Machine, [int]$Wave, [string]$Step, [string]$Detail)
        $entry = [ordered]@{ time = Format-CpwDate (& $clock); wave = $Wave; machine = $Machine; step = $Step; detail = $Detail }
        $events.Add($entry)
        if ($JournalPath) { Add-Content -LiteralPath $JournalPath -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8NoBOM }
    }

    $records = [ordered]@{}
    foreach ($machine in $Plan.machines) {
        $records[$machine.name] = [ordered]@{
            name = $machine.name
            deliveryGroup = $machine.deliveryGroup
            wave = $machine.wave
            state = 'Pending'
            inMaintenanceMode = $false
            detail = $null
            sessionsAtDrain = $null
            messageSent = $false
            forcedLogoff = $false
            forcedLogoffAt = $null
            installed = @()
            drainStartedAt = $null
            drainedAt = $null
            patchStartedAt = $null
            patchFinishedAt = $null
            restartedAt = $null
            registeredAt = $null
            finishedAt = $null
        }
    }

    $setMaintenance = {
        param($Record, [bool]$Enabled, [int]$Wave)
        & $Provider.SetMaintenance $state $Record.name $Enabled
        $Record.inMaintenanceMode = $Enabled
        & $log $Record.name $Wave $(if ($Enabled) { 'MaintenanceOn' } else { 'MaintenanceOff' }) $null
    }
    $finish = {
        param($Record, [string]$FinalState, [string]$Detail, [int]$Wave)
        $Record.state = $FinalState
        $Record.detail = $Detail
        $Record.finishedAt = Format-CpwDate (& $clock)
        & $log $Record.name $Wave $FinalState $Detail
    }

    $waves = [System.Collections.Generic.List[object]]::new()
    $stopReason = $null
    $windowClosed = $false
    & $log $null 0 'Started' "$($Plan.machines.Count) machines in $($Plan.waves.Count) waves on $($Provider.Name)."

    foreach ($planWave in $Plan.waves) {
        $number = [int]$planWave.number
        $waveRecords = @($planWave.machines | ForEach-Object { $records[$_] })
        $result = [ordered]@{
            number = $number
            kind = $planWave.kind
            failureBudget = [int]$planWave.failureBudget
            machines = $planWave.machines
            startedAt = $null
            finishedAt = $null
            completed = 0
            failed = 0
            notDrained = 0
            deferred = 0
            result = $null
        }
        $waves.Add($result)

        if ($stopReason) {
            foreach ($record in $waveRecords) { $record.state = 'NotStarted' }
            $result.result = 'NotStarted'
            continue
        }
        if ((& $clock) -ge $Maintenance.WindowEnd) {
            $windowClosed = $true
            foreach ($record in $waveRecords) {
                $record.state = 'Deferred'
                $record.detail = 'The window closed before this wave started.'
            }
            $result.deferred = $waveRecords.Count
            $result.result = 'Deferred'
            & $log $null $number 'WaveDeferred' 'The window closed before this wave started.'
            continue
        }

        $result.startedAt = Format-CpwDate (& $clock)
        & $log $null $number 'WaveStarted' "$($planWave.kind) wave with $($waveRecords.Count) machines."

        # Drain: maintenance mode on for the whole wave, message the users.
        foreach ($record in $waveRecords) {
            & $setMaintenance $record $true $number
            $record.state = 'Draining'
            $record.drainStartedAt = Format-CpwDate (& $clock)
            $sessions = [int](& $Provider.GetSessionCount $state $record.name)
            $record.sessionsAtDrain = $sessions
            if ($sessions -gt 0 -and $Maintenance.MessageEnabled) {
                & $Provider.SendMessage $state $record.name $Maintenance.MessageTitle $Maintenance.MessageText
                $record.messageSent = $true
                & $log $record.name $number 'MessageSent' "$sessions session(s)."
            }
        }

        $guard = 0
        while (@($waveRecords | Where-Object { $script:TerminalStates -notcontains $_.state }).Count -gt 0) {
            if (++$guard -gt 100000) { throw 'The engine did not converge; this is a bug.' }
            $now = & $clock

            foreach ($record in @($waveRecords | Where-Object state -EQ 'Draining')) {
                $sessions = [int](& $Provider.GetSessionCount $state $record.name)
                $waited = ($now - (ConvertTo-CpwDate $record.drainStartedAt)).TotalMinutes
                if ($sessions -gt 0 -and $waited -ge $Maintenance.DrainTimeoutMinutes) {
                    if ($Maintenance.ForceLogoff -and -not $record.forcedLogoff) {
                        & $Provider.LogoffSessions $state $record.name
                        $record.forcedLogoff = $true
                        $record.forcedLogoffAt = Format-CpwDate $now
                        & $log $record.name $number 'ForcedLogoff' "$sessions session(s) still active after $([int]$waited) minutes."
                        $sessions = [int](& $Provider.GetSessionCount $state $record.name)
                    }
                    elseif ($record.forcedLogoff) {
                        if (($now - (ConvertTo-CpwDate $record.forcedLogoffAt)).TotalMinutes -ge $script:LogoffGraceMinutes) {
                            & $setMaintenance $record $false $number
                            & $finish $record 'NotDrained' "$sessions session(s) still active $($script:LogoffGraceMinutes) minutes after a forced logoff; returned to service unpatched." $number
                        }
                        continue
                    }
                    else {
                        & $setMaintenance $record $false $number
                        & $finish $record 'NotDrained' "$sessions session(s) still active after $($Maintenance.DrainTimeoutMinutes) minutes; returned to service unpatched." $number
                        continue
                    }
                }
                if ($sessions -eq 0) {
                    $record.state = 'Ready'
                    $record.drainedAt = Format-CpwDate $now
                    & $log $record.name $number 'Drained' $null
                }
            }

            $active = @($waveRecords | Where-Object { $_.state -in 'Patching', 'Restarting', 'Verifying' }).Count
            foreach ($record in @($waveRecords | Where-Object state -EQ 'Ready')) {
                if ($now -ge $Maintenance.WindowEnd) {
                    $windowClosed = $true
                    & $setMaintenance $record $false $number
                    & $finish $record 'Deferred' 'The window closed before patching started; returned to service unpatched.' $number
                    continue
                }
                if ($active -ge $Maintenance.Concurrency) { break }
                & $Provider.StartPatch $state $record.name
                $record.state = 'Patching'
                $record.patchStartedAt = Format-CpwDate $now
                & $log $record.name $number 'PatchStarted' $null
                $active++
            }

            foreach ($record in @($waveRecords | Where-Object state -EQ 'Patching')) {
                $status = & $Provider.GetPatchStatus $state $record.name $Maintenance
                if ($status.Status -eq 'Succeeded') {
                    $record.installed = @($status.Installed)
                    $record.patchFinishedAt = Format-CpwDate $now
                    & $log $record.name $number 'Patched' "$(@($status.Installed).Count) item(s) installed."
                    & $Provider.StartRestart $state $record.name
                    $record.state = 'Restarting'
                    $record.restartedAt = Format-CpwDate $now
                    & $log $record.name $number 'Restarted' $null
                }
                elseif ($status.Status -eq 'Failed') {
                    $record.patchFinishedAt = Format-CpwDate $now
                    & $finish $record 'Failed' "Patching failed: $($status.Detail)" $number
                }
                elseif (($now - (ConvertTo-CpwDate $record.patchStartedAt)).TotalMinutes -ge $script:PatchTimeoutMinutes) {
                    & $finish $record 'Failed' "Patching did not finish within $($script:PatchTimeoutMinutes) minutes." $number
                }
            }

            foreach ($record in @($waveRecords | Where-Object state -EQ 'Restarting')) {
                $registration = [string](& $Provider.GetRegistration $state $record.name)
                if ($registration -eq 'Registered') {
                    $record.registeredAt = Format-CpwDate $now
                    $record.state = 'Verifying'
                    & $log $record.name $number 'Registered' $null
                }
                elseif (($now - (ConvertTo-CpwDate $record.restartedAt)).TotalMinutes -ge $Maintenance.RebootTimeoutMinutes) {
                    & $finish $record 'Failed' "Did not register with the Delivery Controller within $($Maintenance.RebootTimeoutMinutes) minutes of the restart ($registration)." $number
                }
            }

            foreach ($record in @($waveRecords | Where-Object state -EQ 'Verifying')) {
                $services = & $Provider.GetServiceStatus $state $record.name $Maintenance.Services
                $stopped = @($services.Keys | Where-Object { $services[$_] -ne 'Running' })
                $remaining = if ($Maintenance.WindowsUpdates) { [int](& $Provider.GetApplicableUpdates $state $record.name $Maintenance) } else { 0 }
                if ($stopped.Count -gt 0) {
                    $list = ($stopped | ForEach-Object { "$_ is $($services[$_])" }) -join ', '
                    & $finish $record 'Failed' "Registered, but $list after the restart." $number
                }
                elseif ($remaining -gt 0) {
                    & $finish $record 'Failed' "$remaining requested update(s) still applicable after the restart." $number
                }
                else {
                    & $setMaintenance $record $false $number
                    & $finish $record 'Completed' $null $number
                }
            }

            if (@($waveRecords | Where-Object { $script:TerminalStates -notcontains $_.state }).Count -gt 0) {
                & $Provider.Wait $state $Maintenance.PollMinutes
            }
        }

        $result.finishedAt = Format-CpwDate (& $clock)
        $result.completed = @($waveRecords | Where-Object state -EQ 'Completed').Count
        $result.failed = @($waveRecords | Where-Object state -EQ 'Failed').Count
        $result.notDrained = @($waveRecords | Where-Object state -EQ 'NotDrained').Count
        $result.deferred = @($waveRecords | Where-Object state -EQ 'Deferred').Count
        if ($result.failed -gt $result.failureBudget) {
            $result.result = 'Stopped'
            $failedNames = @($waveRecords | Where-Object state -EQ 'Failed' | ForEach-Object { $_.name }) -join ', '
            $label = if ($planWave.kind -eq 'Canary') { 'The canary wave' } else { "Wave $number" }
            $stopReason = "$label had $($result.failed) failed machine(s) ($failedNames) and its failure budget is $($result.failureBudget); no further wave was started."
            & $log $null $number 'Stopped' $stopReason
        }
        else {
            $result.result = 'Passed'
            & $log $null $number 'WavePassed' "$($result.completed) completed, $($result.failed) failed, $($result.notDrained) not drained, $($result.deferred) deferred."
        }
    }

    $all = @($records.Values)
    $totals = [ordered]@{
        planned = $all.Count
        completed = @($all | Where-Object state -EQ 'Completed').Count
        failed = @($all | Where-Object state -EQ 'Failed').Count
        notDrained = @($all | Where-Object state -EQ 'NotDrained').Count
        deferred = @($all | Where-Object state -EQ 'Deferred').Count
        notStarted = @($all | Where-Object state -EQ 'NotStarted').Count
        excluded = @($Plan.exclusions).Count
        leftInMaintenance = @($all | Where-Object inMaintenanceMode).Count
    }
    $outcome = if ($stopReason) { 'Stopped' }
    elseif ($windowClosed) { 'WindowClosed' }
    elseif ($totals.failed + $totals.notDrained -gt 0) { 'CompletedWithExceptions' }
    else { 'Completed' }
    & $log $null 0 'Finished' $outcome

    [ordered]@{
        kind = 'citrix-patch-waves-run'
        schemaVersion = $script:SchemaVersion
        toolVersion = $script:ModuleVersion
        provider = $Provider.Name
        simulation = [bool]$Provider.IsSimulation
        maintenance = $Plan.maintenance
        startedAt = Format-CpwDate $startedAt
        finishedAt = Format-CpwDate (& $clock)
        outcome = $outcome
        stopReason = $stopReason
        totals = $totals
        waves = $waves.ToArray()
        machines = $all
        exclusions = $Plan.exclusions
        warnings = $Plan.warnings
        events = $events.ToArray()
    }
}
