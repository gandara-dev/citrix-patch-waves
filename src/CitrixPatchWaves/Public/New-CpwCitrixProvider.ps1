function New-CpwCitrixProvider {
    <#
    .SYNOPSIS
    Creates a read-only provider for a real Citrix Virtual Apps and Desktops site.

    .DESCRIPTION
    In this version the provider only reads: it lists machines with
    Get-BrokerMachine so Get-CpwPlan can plan against a real site. Every action
    (maintenance mode, messages, patching, restarts) throws, so a real site can
    be planned but not changed. Execution against a real site is on the
    roadmap in docs/roadmap.md.

    Needs the Citrix Broker PowerShell SDK (a Delivery Controller or the
    Remote PowerShell SDK) and a Citrix Read Only Administrator is enough.

    .EXAMPLE
    $provider = New-CpwCitrixProvider -AdminAddress ddc01.corp.example.test
    Get-CpwPlan -Maintenance $maintenance -Provider $provider
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$AdminAddress = 'localhost'
    )

    if (-not (Get-Command -Name 'Get-BrokerMachine' -ErrorAction SilentlyContinue)) {
        throw 'Get-BrokerMachine was not found. Run on a Delivery Controller or install the Citrix Remote PowerShell SDK.'
    }

    $readOnly = {
        throw 'This version plans against a real Citrix site but does not change it. Run the change with the simulation, or follow docs/roadmap.md.'
    }

    [pscustomobject]@{
        Name = "Citrix ($AdminAddress)"
        IsSimulation = $false
        State = @{ AdminAddress = $AdminAddress }

        Now = { param($State) [void]$State; [DateTimeOffset]::UtcNow }
        Wait = { param($State, [int]$Minutes) [void]$State; Start-Sleep -Seconds ($Minutes * 60) }

        GetMachines = {
            param($State)
            foreach ($machine in @(Get-BrokerMachine -AdminAddress $State.AdminAddress -MaxRecordCount 100000)) {
                [pscustomobject]@{
                    Name = (($machine.MachineName -split '\\')[-1]).ToUpperInvariant()
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

        GetSessionCount = $readOnly
        SetMaintenance = $readOnly
        SendMessage = $readOnly
        LogoffSessions = $readOnly
        StartPatch = $readOnly
        GetPatchStatus = $readOnly
        StartRestart = $readOnly
        GetRegistration = $readOnly
        GetServiceStatus = $readOnly
        GetApplicableUpdates = $readOnly
    }
}
