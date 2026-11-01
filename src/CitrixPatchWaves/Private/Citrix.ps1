# Helpers for the Citrix provider. Every action receives the short machine
# name; the provider remembers the full name, the DNS name, and the hosting
# connection from the Get-BrokerMachine call that planned the change.

function Get-CpwCitrixMachine {
    param([hashtable]$State, [string]$Name)

    $machine = $State.Machines[$Name]
    if ($null -eq $machine) { throw "$Name was not read from the site; plan the change with this provider first." }
    $machine
}

function Get-CpwBrokerSession {
    param([hashtable]$State, [string]$Name)

    $machine = Get-CpwCitrixMachine -State $State -Name $Name
    Get-BrokerSession -AdminAddress $State.AdminAddress -MachineName $machine.MachineName -MaxRecordCount 10000
}

function Invoke-CpwRemoteCommand {
    param([hashtable]$State, [string]$Name, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())

    $machine = Get-CpwCitrixMachine -State $State -Name $Name
    if (-not $machine.DnsName) { throw "$Name has no DNS name in Citrix, so it cannot be reached over WinRM." }
    $parameters = @{ ComputerName = $machine.DnsName; ScriptBlock = $ScriptBlock; ArgumentList = $ArgumentList; ErrorAction = 'Stop' }
    if ($State.Credential) { $parameters.Credential = $State.Credential }
    Invoke-Command @parameters
}
