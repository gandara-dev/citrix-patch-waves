# The maintenance settings as they appear in plans, runs, and change records.
function ConvertTo-CpwMaintenanceSummary {
    param([pscustomobject]$Maintenance)

    [ordered]@{
        name = $Maintenance.Name
        change = $Maintenance.Change
        windowStart = Format-CpwDate $Maintenance.WindowStart
        windowEnd = Format-CpwDate $Maintenance.WindowEnd
        deliveryGroups = $Maintenance.DeliveryGroups
        canarySize = $Maintenance.CanarySize
        waveSize = $Maintenance.WaveSize
        concurrency = $Maintenance.Concurrency
        failureBudget = $Maintenance.FailureBudget
        drainTimeoutMinutes = $Maintenance.DrainTimeoutMinutes
        forceLogoff = $Maintenance.ForceLogoff
        message = if ($Maintenance.MessageEnabled) { [ordered]@{ title = $Maintenance.MessageTitle; text = $Maintenance.MessageText } } else { $null }
        windowsUpdates = if ($Maintenance.WindowsUpdates) { $Maintenance.UpdateCategories } else { @() }
        software = @($Maintenance.Software | ForEach-Object { [ordered]@{ name = $_.Name; wingetId = $_.WingetId } })
        rebootTimeoutMinutes = $Maintenance.RebootTimeoutMinutes
        services = $Maintenance.Services
    }
}

# One sentence for the top of the change record and the console output.
function Get-CpwOutcomeText {
    param([System.Collections.IDictionary]$Run)

    $t = $Run.totals
    $patched = "$($t.completed) of $($t.planned) machines patched"
    switch ($Run.outcome) {
        'Completed' { "Completed: $patched." }
        'CompletedWithExceptions' {
            $parts = @()
            if ($t.failed) { $parts += "$($t.failed) failed and left in maintenance mode" }
            if ($t.notDrained) { $parts += "$($t.notDrained) returned to service unpatched because sessions did not end" }
            "Completed with exceptions: $patched; $($parts -join '; ')."
        }
        'Stopped' { "Stopped: $patched. $($Run.stopReason)" }
        'WindowClosed' { "Window closed: $patched; $($t.deferred) deferred to the next window." }
        default { $Run.outcome }
    }
}
