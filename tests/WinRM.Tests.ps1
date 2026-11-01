[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with the It blocks.')]
param()

# The service checks of the Citrix provider against a real Windows machine:
# the Broker SDK is mocked, WinRM is not. CI enables PowerShell remoting on the
# Windows runner; elsewhere the tests are skipped.
BeforeDiscovery {
    $winRm = $IsWindows -and $null -ne (Test-WSMan -ComputerName localhost -ErrorAction SilentlyContinue)
}

Describe 'Citrix provider over WinRM' -Skip:(-not $winRm) {
    BeforeAll {
        function global:Get-BrokerMachine { [CmdletBinding()] param([string]$AdminAddress, [int]$MaxRecordCount, [string]$MachineName) [void]$AdminAddress; [void]$MaxRecordCount; [void]$MachineName }

        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $repositoryRoot 'src/CitrixPatchWaves/CitrixPatchWaves.psd1') -Force

        Mock -ModuleName CitrixPatchWaves Get-BrokerMachine {
            [pscustomobject]@{
                MachineName = "CORP\$env:COMPUTERNAME"; DNSName = 'localhost'; DesktopGroupName = 'DG-LIS-W11-RPC-ENGINEERING'
                CatalogName = 'MC-LIS-W11-RPC-ENGINEERING'; ProvisioningType = 'Manual'; AllocationType = 'Static'; SessionSupport = 'SingleSession'
                InMaintenanceMode = $false; RegistrationState = 'Registered'; PowerState = 'On'; SessionCount = 0; HypervisorConnectionName = $null
            }
        }
        $provider = New-CpwCitrixProvider -AdminAddress 'ddc01.corp.example.test'
        & $provider.GetMachines $provider.State | Out-Null
        $name = $env:COMPUTERNAME.ToUpperInvariant()
    }

    It 'reads the status of running, stopped, and missing services' {
        $stopped = Get-Service | Where-Object { $_.Status -eq 'Stopped' -and $_.StartType -eq 'Disabled' } | Select-Object -First 1
        $services = @('Winmgmt', 'CpwNoSuchService') + @($stopped.Name | Where-Object { $_ })
        $status = & $provider.GetServiceStatus $provider.State $name $services
        $status['Winmgmt'] | Should -Be 'Running'
        $status['CpwNoSuchService'] | Should -Be 'NotInstalled'
        if ($stopped) { $status[$stopped.Name] | Should -Be 'Stopped' }
    }
}
