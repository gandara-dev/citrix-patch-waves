function New-CpwCitrixProvider {
    <#
    .SYNOPSIS
    Creates a provider for a real Citrix Virtual Apps and Desktops site.

    .DESCRIPTION
    The provider plans against the site with Get-BrokerMachine and, in this
    version, runs restart-only changes: maintenance mode, user messages, forced
    logoff, the restart, registration, and the service checks. It does not
    install updates yet, so Invoke-CpwMaintenance refuses a change that asks for
    Windows updates or applications before changing anything (see
    docs/roadmap.md).

    Citrix calls go through the Broker PowerShell SDK (a Delivery Controller or
    the Remote PowerShell SDK). A machine with a hosting connection restarts
    through New-BrokerHostingPowerAction; a machine without one (Remote PC
    Access) restarts over WinRM. Service checks always use WinRM, with
    -Credential when given and the current account otherwise.

    Planning needs a Citrix Read Only Administrator. A change needs the
    permissions listed in docs/release-verification.md.

    .EXAMPLE
    $provider = New-CpwCitrixProvider -AdminAddress ddc01.corp.example.test
    Get-CpwPlan -Maintenance $maintenance -Provider $provider
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$AdminAddress = 'localhost',

        [pscredential]$Credential
    )

    if (-not (Get-Command -Name 'Get-BrokerMachine' -ErrorAction SilentlyContinue)) {
        throw 'Get-BrokerMachine was not found. Run on a Delivery Controller or install the Citrix Remote PowerShell SDK.'
    }

    $noPatching = {
        throw 'This version restarts machines on a real Citrix site but does not install updates. See docs/roadmap.md.'
    }

    [pscustomobject]@{
        Name = "Citrix ($AdminAddress)"
        IsSimulation = $false
        CanPatch = $false
        State = @{
            AdminAddress = $AdminAddress
            Credential = $Credential
            Machines = @{}
        }

        Now = { param($State) [void]$State; [DateTimeOffset]::UtcNow }
        Wait = { param($State, [int]$Minutes) [void]$State; Start-Sleep -Seconds ($Minutes * 60) }

        GetMachines = {
            param($State)
            foreach ($machine in @(Get-BrokerMachine -AdminAddress $State.AdminAddress -MaxRecordCount 100000)) {
                $name = Get-CpwShortName $machine.MachineName
                $State.Machines[$name] = @{
                    MachineName = $machine.MachineName
                    DnsName = $machine.DNSName
                    HostingConnection = $machine.HypervisorConnectionName
                    RestartedAt = $null
                    SeenUnregistered = $false
                }
                [pscustomobject]@{
                    Name = $name
                    MachineName = $machine.MachineName
                    DnsName = $machine.DNSName
                    DeliveryGroup = $machine.DesktopGroupName
                    CatalogName = $machine.CatalogName
                    ProvisioningType = [string]$machine.ProvisioningType
                    AllocationType = [string]$machine.AllocationType
                    SessionSupport = [string]$machine.SessionSupport
                    InMaintenanceMode = [bool]$machine.InMaintenanceMode
                    RegistrationState = [string]$machine.RegistrationState
                    PowerState = [string]$machine.PowerState
                    SessionCount = [int]$machine.SessionCount
                }
            }
        }

        GetSessionCount = {
            param($State, [string]$Name)
            @(Get-CpwBrokerSession -State $State -Name $Name).Count
        }

        SetMaintenance = {
            param($State, [string]$Name, [bool]$Enabled)
            $machine = Get-CpwCitrixMachine -State $State -Name $Name
            Set-BrokerMachineMaintenanceMode -AdminAddress $State.AdminAddress -InputObject $machine.MachineName -MaintenanceMode $Enabled
        }

        SendMessage = {
            param($State, [string]$Name, [string]$Title, [string]$Text)
            $sessions = @(Get-CpwBrokerSession -State $State -Name $Name)
            if ($sessions.Count -gt 0) {
                Send-BrokerSessionMessage -AdminAddress $State.AdminAddress -InputObject $sessions -MessageStyle Information -Title $Title -Text $Text
            }
        }

        LogoffSessions = {
            param($State, [string]$Name)
            $sessions = @(Get-CpwBrokerSession -State $State -Name $Name)
            if ($sessions.Count -gt 0) {
                Stop-BrokerSession -AdminAddress $State.AdminAddress -InputObject $sessions
            }
        }

        StartPatch = $noPatching
        GetPatchStatus = $noPatching
        GetApplicableUpdates = $noPatching

        StartRestart = {
            param($State, [string]$Name)
            $machine = Get-CpwCitrixMachine -State $State -Name $Name
            if ($machine.HostingConnection) {
                New-BrokerHostingPowerAction -AdminAddress $State.AdminAddress -MachineName $machine.MachineName -Action Restart | Out-Null
            }
            else {
                # Remote PC Access has no hosting connection. shutdown.exe returns
                # at once, so the WinRM call ends before the machine goes down;
                # p:2:17 records a planned security-fix restart in the event log.
                Invoke-CpwRemoteCommand -State $State -Name $Name -ScriptBlock {
                    shutdown.exe /r /t 30 /d p:2:17 /c 'Citrix Patch Waves maintenance restart'
                    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe exited with $LASTEXITCODE." }
                } | Out-Null
            }
            $machine.RestartedAt = [DateTimeOffset]::UtcNow
            $machine.SeenUnregistered = $false
        }

        GetRegistration = {
            param($State, [string]$Name)
            $machine = Get-CpwCitrixMachine -State $State -Name $Name
            $broker = Get-BrokerMachine -AdminAddress $State.AdminAddress -MachineName $machine.MachineName
            $registration = [string]$broker.RegistrationState
            if ($registration -ne 'Registered') {
                $machine.SeenUnregistered = $true
                return $registration
            }
            # Right after the restart command the controller still reports the
            # machine as registered. It counts as back only once it was seen
            # unregistered or deregistered after the restart was requested.
            $deregistered = if ($broker.LastDeregistrationTime) { [DateTimeOffset]::new(([datetime]$broker.LastDeregistrationTime).ToUniversalTime()) }
            if ($machine.SeenUnregistered -or ($deregistered -and $deregistered -ge $machine.RestartedAt.AddMinutes(-1))) {
                return 'Registered'
            }
            'Restarting'
        }

        GetServiceStatus = {
            param($State, [string]$Name, [string[]]$Services)
            $found = Invoke-CpwRemoteCommand -State $State -Name $Name -ArgumentList (, $Services) -ScriptBlock {
                param([string[]]$Names)
                foreach ($serviceName in $Names) {
                    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                    [pscustomobject]@{ Name = $serviceName; Status = if ($service) { [string]$service.Status } else { 'NotInstalled' } }
                }
            }
            $status = [ordered]@{}
            foreach ($service in $Services) {
                $match = @($found | Where-Object Name -EQ $service)
                $status[$service] = if ($match.Count -gt 0) { [string]$match[0].Status } else { 'Unknown' }
            }
            $status
        }
    }
}
