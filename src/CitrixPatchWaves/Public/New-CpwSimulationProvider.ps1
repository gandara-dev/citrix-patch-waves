$script:SimulationFailures = @('PatchFails', 'NoRegistration', 'ServiceStopped', 'UpdatesRemain', 'SessionsNeverEnd', 'LogoffFails')

function New-CpwSimulationProvider {
    <#
    .SYNOPSIS
    Creates a provider backed by a fictional, deterministic Citrix site.

    .DESCRIPTION
    The simulated site has three delivery groups that follow the naming
    convention of the other gandara-dev Citrix projects:

    - DG-LIS-W11-DED-FINANCE: 24 persistent MCS desktops (LISW11FIN001-024);
      LISW11FIN019 is already in maintenance mode and LISW11FIN022 is not
      registered, so the planner leaves both alone.
    - DG-LIS-W11-RPC-ENGINEERING: 12 Remote PC Access machines
      (LISW11ENG001-012).
    - DG-LIS-W11-POOL-SUPPORT: 8 pooled MCS desktops (LISW11SUP001-008), which
      the planner excludes because MCS rolls out image updates itself.

    Sessions end (counted from the moment a machine goes into maintenance
    mode), patches finish, and machines register again at fixed, per-machine
    times, on a virtual clock that starts at StartTime and only
    moves when the engine waits. The same input always gives the same run, and
    a whole change window runs in about a second.

    -Failure injects a problem on named machines: PatchFails,
    NoRegistration, ServiceStopped, UpdatesRemain, SessionsNeverEnd, or
    LogoffFails (a session that survives a forced logoff).

    .EXAMPLE
    $provider = New-CpwSimulationProvider -StartTime $maintenance.WindowStart -Failure @{ LISW11FIN001 = 'PatchFails' }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [DateTimeOffset]$StartTime = [DateTimeOffset]::new(2026, 10, 4, 21, 0, 0, [TimeSpan]::Zero),

        [hashtable]$Failure = @{}
    )

    $failures = @{}
    foreach ($key in $Failure.Keys) {
        $kind = [string]$Failure[$key]
        if ($script:SimulationFailures -notcontains $kind) {
            throw "Unknown failure '$kind' for $key. Use one of: $($script:SimulationFailures -join ', ')."
        }
        $failures[(Get-CpwShortName $key)] = $kind
    }

    $machines = [ordered]@{}
    $groups = @(
        @{ Prefix = 'LISW11FIN'; Count = 24; Group = 'DG-LIS-W11-DED-FINANCE'; Catalog = 'MC-LIS-W11-DED-FINANCE'; Provisioning = 'MCS'; Allocation = 'Static'; Seed = 1 }
        @{ Prefix = 'LISW11ENG'; Count = 12; Group = 'DG-LIS-W11-RPC-ENGINEERING'; Catalog = 'MC-LIS-W11-RPC-ENGINEERING'; Provisioning = 'Manual'; Allocation = 'Static'; Seed = 2 }
        @{ Prefix = 'LISW11SUP'; Count = 8; Group = 'DG-LIS-W11-POOL-SUPPORT'; Catalog = 'MC-LIS-W11-POOL-SUPPORT'; Provisioning = 'MCS'; Allocation = 'Random'; Seed = 3 }
    )
    foreach ($group in $groups) {
        for ($i = 1; $i -le $group.Count; $i++) {
            $name = '{0}{1:000}' -f $group.Prefix, $i
            $seed = $group.Seed
            # Deterministic session pattern, in minutes after the machine goes
            # into maintenance mode: some machines are idle, most have one or
            # two sessions that end within the hour, and a few have a session
            # that outlasts a 60-minute drain.
            $pattern = ($i * 7 + $seed * 3) % 10
            $sessionEnds = switch ($pattern) {
                { $_ -le 2 } { @(); break }
                { $_ -le 6 } { @((3 + ($i * 13 + $seed) % 35)); break }
                { $_ -le 8 } { @((10 + ($i * 5) % 30), (20 + ($i * 11) % 40)); break }
                default { @((70 + $i % 20)) }
            }
            $machines[$name] = @{
                Name = $name
                MachineName = "CORP\$name"
                DnsName = "$($name.ToLowerInvariant()).corp.example.test"
                DeliveryGroup = $group.Group
                CatalogName = $group.Catalog
                ProvisioningType = $group.Provisioning
                AllocationType = $group.Allocation
                SessionSupport = 'SingleSession'
                InMaintenanceMode = ($name -eq 'LISW11FIN019')
                RegistrationState = if ($name -eq 'LISW11FIN022') { 'Unregistered' } else { 'Registered' }
                PowerState = if ($name -eq 'LISW11FIN022') { 'Off' } else { 'On' }
                SessionEnds = [int[]]$sessionEnds
                LoggedOff = $false
                PatchMinutes = 14 + ($i * 7 + $seed) % 16
                RegisterMinutes = 3 + ($i + $seed) % 5
                MaintenanceAt = $null
                PatchStartedAt = $null
                RestartedAt = $null
                Failure = $failures[$name]
                Messages = [System.Collections.Generic.List[string]]::new()
                Index = $i
            }
        }
    }
    foreach ($name in $failures.Keys) {
        if (-not $machines.Contains($name)) { throw "The simulated site has no machine named $name." }
    }

    $state = @{
        Start = $StartTime.ToUniversalTime()
        Now = $StartTime.ToUniversalTime()
        Machines = $machines
        CountSessions = {
            param($State, $Machine)
            if ($Machine.Failure -eq 'LogoffFails') { return 1 }
            if ($Machine.LoggedOff) { return 0 }
            if ($Machine.Failure -eq 'SessionsNeverEnd') { return 1 }
            if ($null -eq $Machine.MaintenanceAt) { return $Machine.SessionEnds.Count }
            $elapsed = ($State.Now - $Machine.MaintenanceAt).TotalMinutes
            @($Machine.SessionEnds | Where-Object { $_ -gt $elapsed }).Count
        }
    }

    [pscustomobject]@{
        Name = 'Simulation'
        IsSimulation = $true
        State = $state

        Now = { param($State) $State.Now }
        Wait = { param($State, [int]$Minutes) $State.Now = $State.Now.AddMinutes($Minutes) }

        GetMachines = {
            param($State)
            foreach ($machine in $State.Machines.Values) {
                [pscustomobject]@{
                    Name = $machine.Name
                    MachineName = $machine.MachineName
                    DnsName = $machine.DnsName
                    DeliveryGroup = $machine.DeliveryGroup
                    CatalogName = $machine.CatalogName
                    ProvisioningType = $machine.ProvisioningType
                    AllocationType = $machine.AllocationType
                    SessionSupport = $machine.SessionSupport
                    InMaintenanceMode = $machine.InMaintenanceMode
                    RegistrationState = $machine.RegistrationState
                    PowerState = $machine.PowerState
                    SessionCount = & $State.CountSessions $State $machine
                }
            }
        }

        GetSessionCount = { param($State, [string]$Name) & $State.CountSessions $State $State.Machines[$Name] }

        SetMaintenance = {
            param($State, [string]$Name, [bool]$Enabled)
            $machine = $State.Machines[$Name]
            $machine.InMaintenanceMode = $Enabled
            if ($Enabled -and $null -eq $machine.MaintenanceAt) { $machine.MaintenanceAt = $State.Now }
        }

        SendMessage = {
            param($State, [string]$Name, [string]$Title, [string]$Text)
            $State.Machines[$Name].Messages.Add("$Title`: $Text")
        }

        LogoffSessions = { param($State, [string]$Name) $State.Machines[$Name].LoggedOff = $true }

        StartPatch = { param($State, [string]$Name) $State.Machines[$Name].PatchStartedAt = $State.Now }

        GetPatchStatus = {
            param($State, [string]$Name, $Maintenance)
            $machine = $State.Machines[$Name]
            if (($State.Now - $machine.PatchStartedAt).TotalMinutes -lt $machine.PatchMinutes) {
                return [pscustomobject]@{ Status = 'Running'; Detail = $null; Installed = @() }
            }
            if ($machine.Failure -eq 'PatchFails') {
                return [pscustomobject]@{
                    Status = 'Failed'
                    Detail = 'Windows Update returned 0x80240022 (WU_E_ALL_UPDATES_FAILED): no update was installed.'
                    Installed = @()
                }
            }
            $installed = [System.Collections.Generic.List[string]]::new()
            if ($Maintenance.WindowsUpdates) {
                if ($Maintenance.UpdateCategories -contains 'Security Updates') {
                    $installed.Add('2026-10 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5990117)')
                }
                if ($Maintenance.UpdateCategories -contains 'Critical Updates') {
                    $installed.Add('2026-10 Servicing Stack Update for Windows 11 Version 24H2 (KB5990102)')
                }
            }
            foreach ($app in $Maintenance.Software) {
                if ($machine.Index % 3 -ne 0) { $installed.Add("$($app.Name) ($($app.WingetId)) updated") }
            }
            [pscustomobject]@{ Status = 'Succeeded'; Detail = $null; Installed = $installed.ToArray() }
        }

        StartRestart = {
            param($State, [string]$Name)
            $machine = $State.Machines[$Name]
            $machine.RestartedAt = $State.Now
            $machine.RegistrationState = 'Unregistered'
            $machine.LoggedOff = $true
        }

        GetRegistration = {
            param($State, [string]$Name)
            $machine = $State.Machines[$Name]
            if ($machine.Failure -ne 'NoRegistration' -and $machine.RegistrationState -ne 'Registered' -and
                ($State.Now - $machine.RestartedAt).TotalMinutes -ge $machine.RegisterMinutes) {
                $machine.RegistrationState = 'Registered'
            }
            $machine.RegistrationState
        }

        GetServiceStatus = {
            param($State, [string]$Name, [string[]]$Services)
            $machine = $State.Machines[$Name]
            $status = [ordered]@{}
            foreach ($service in $Services) {
                $status[$service] = if ($machine.Failure -eq 'ServiceStopped' -and $service -eq 'BrokerAgent') { 'Stopped' } else { 'Running' }
            }
            $status
        }

        GetApplicableUpdates = {
            param($State, [string]$Name)
            if ($State.Machines[$Name].Failure -eq 'UpdatesRemain') { 1 } else { 0 }
        }
    }
}
