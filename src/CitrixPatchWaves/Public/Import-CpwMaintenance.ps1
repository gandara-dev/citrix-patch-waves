function Import-CpwMaintenance {
    <#
    .SYNOPSIS
    Reads and validates a maintenance file and applies the defaults.

    .DESCRIPTION
    Throws with every problem when the definition is invalid. The result is a
    normalized object used by Get-CpwPlan and Invoke-CpwMaintenance, with the
    window as UTC DateTimeOffset values and every default filled in.

    .EXAMPLE
    $maintenance = Import-CpwMaintenance ./samples/lisbon-october.maintenance.json
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Object')]
        $InputObject
    )

    process {
        $definition = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Maintenance file not found: $Path" }
            try {
                Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            }
            catch {
                throw "The maintenance file is not valid JSON: $($_.Exception.Message)"
            }
        }
        else {
            $InputObject
        }

        $problems = @(Test-CpwMaintenance -InputObject $definition)
        if ($problems.Count -gt 0) {
            $lines = $problems | ForEach-Object { if ($_.Path) { "$($_.Path): $($_.Message)" } else { $_.Message } }
            throw "The maintenance definition is not valid:`n - $($lines -join "`n - ")"
        }

        $window = Get-CpwValue $definition 'window'
        $target = Get-CpwValue $definition 'target'
        $waves = Get-CpwValue $definition 'waves'
        $drain = Get-CpwValue $definition 'drain'
        $message = Get-CpwValue $drain 'message'
        $patch = Get-CpwValue $definition 'patch'
        $windowsUpdates = Get-CpwValue $patch 'windowsUpdates'
        $reboot = Get-CpwValue $definition 'reboot'
        $verify = Get-CpwValue $definition 'verify'

        $messageEnabled = [bool](Get-CpwValue $message 'enabled' $false)
        $categories = @(Get-CpwList $windowsUpdates 'categories')
        if ($categories.Count -eq 0) { $categories = @('Security Updates', 'Critical Updates') }
        $services = @(Get-CpwList $verify 'services')
        if (-not (Test-CpwHasValue $verify 'services')) { $services = @('BrokerAgent') }

        [pscustomobject]@{
            Name = (Get-CpwValue $definition 'name').Trim()
            Change = Get-CpwValue $definition 'change'
            WindowStart = ConvertTo-CpwDate (Get-CpwValue $window 'start')
            WindowEnd = ConvertTo-CpwDate (Get-CpwValue $window 'end')
            DeliveryGroups = [string[]]@(Get-CpwList $target 'deliveryGroups' | ForEach-Object { $_.Trim() })
            Include = [string[]]@(Get-CpwList $target 'include' | ForEach-Object { Get-CpwShortName $_ })
            Exclude = [string[]]@(Get-CpwList $target 'exclude' | ForEach-Object { Get-CpwShortName $_ })
            CanarySize = [int](Get-CpwValue $waves 'canarySize' 1)
            WaveSize = [int](Get-CpwValue $waves 'waveSize' 10)
            Concurrency = [int](Get-CpwValue $waves 'concurrency' 5)
            FailureBudget = [int](Get-CpwValue $waves 'failureBudget' 0)
            PollMinutes = [int](Get-CpwValue $waves 'pollMinutes' 1)
            DrainTimeoutMinutes = [int](Get-CpwValue $drain 'timeoutMinutes' 60)
            ForceLogoff = [bool](Get-CpwValue $drain 'forceLogoff' $false)
            MessageEnabled = $messageEnabled
            MessageTitle = if ($messageEnabled) { Get-CpwValue $message 'title' } else { $null }
            MessageText = if ($messageEnabled) { Get-CpwValue $message 'text' } else { $null }
            WindowsUpdates = [bool](Get-CpwValue $windowsUpdates 'enabled' $true)
            UpdateCategories = [string[]]$categories
            Software = @(Get-CpwList $patch 'software' | ForEach-Object {
                    [pscustomobject]@{ Name = (Get-CpwValue $_ 'name').Trim(); WingetId = Get-CpwValue $_ 'wingetId' }
                })
            RebootTimeoutMinutes = [int](Get-CpwValue $reboot 'timeoutMinutes' 30)
            Services = [string[]]$services
        }
    }
}
