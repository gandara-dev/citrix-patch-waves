function Get-CpwPlan {
    <#
    .SYNOPSIS
    Shows which machines go in which wave, and which are left out and why.

    .DESCRIPTION
    Reads the machines from the provider and never changes anything. Machines
    are left out when the maintenance file excludes them, when they are pooled
    MCS or PVS machines (the image is updated instead), when they are already in
    maintenance mode, or when they are not registered before the change.

    The canary wave takes machines from each delivery group in turn, so every
    group is tested before the rest. The canary has a failure budget of zero:
    one failure stops the change. Later waves use waves.failureBudget.

    .EXAMPLE
    Get-CpwPlan -Maintenance (Import-CpwMaintenance ./samples/lisbon-october.maintenance.json) -Provider (New-CpwSimulationProvider)
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Maintenance,

        [Parameter(Mandatory)]
        [pscustomobject]$Provider
    )

    $machines = @(& $Provider.GetMachines $Provider.State)
    $groupOrder = @{}
    for ($index = 0; $index -lt $Maintenance.DeliveryGroups.Count; $index++) {
        $groupOrder[$Maintenance.DeliveryGroups[$index].ToUpperInvariant()] = $index
    }
    $include = @{}
    foreach ($name in $Maintenance.Include) { $include[$name] = $true }
    $exclude = @{}
    foreach ($name in $Maintenance.Exclude) { $exclude[$name] = $true }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $exclusions = [System.Collections.Generic.List[object]]::new()
    $selected = [System.Collections.Generic.List[object]]::new()
    $found = @{}
    $groupsSeen = @{}

    foreach ($machine in $machines) {
        $name = Get-CpwShortName $machine.Name
        $groupKey = ([string]$machine.DeliveryGroup).ToUpperInvariant()
        $inGroup = $groupOrder.ContainsKey($groupKey)
        if (-not ($inGroup -or $include.ContainsKey($name))) { continue }
        $found[$name] = $true
        if ($inGroup) { $groupsSeen[$groupKey] = $true }

        $reason = $null
        if ($exclude.ContainsKey($name)) {
            $reason = 'Excluded in the maintenance file.'
        }
        elseif ($machine.ProvisioningType -eq 'PVS') {
            $reason = 'Streamed by PVS: update the vDisk instead.'
        }
        elseif ($machine.ProvisioningType -eq 'MCS' -and $machine.AllocationType -eq 'Random') {
            $reason = 'Pooled MCS desktop: update the master image and let MCS roll it out.'
        }
        elseif ($machine.InMaintenanceMode) {
            $reason = 'Already in maintenance mode before the change; left untouched so it does not go back into service by mistake.'
        }
        elseif ($machine.RegistrationState -ne 'Registered') {
            $reason = "Not registered before the change ($($machine.RegistrationState), power $($machine.PowerState)); fix it first so a problem after the reboot is not blamed on the patch."
        }

        $entry = [ordered]@{
            name = $name
            machineName = $machine.MachineName
            deliveryGroup = $machine.DeliveryGroup
            catalog = $machine.CatalogName
            provisioning = $machine.ProvisioningType
            allocation = $machine.AllocationType
            sessionsAtPlan = [int]$machine.SessionCount
        }
        if ($reason) {
            $entry.reason = $reason
            $exclusions.Add($entry)
        }
        else {
            $entry.order = if ($inGroup) { $groupOrder[$groupKey] } else { $groupOrder.Count }
            $selected.Add($entry)
        }
    }

    foreach ($name in $Maintenance.Include) {
        if (-not $found.ContainsKey($name)) { $warnings.Add("$name is in target.include but was not found in the site.") }
    }
    foreach ($group in $Maintenance.DeliveryGroups) {
        if (-not $groupsSeen.ContainsKey($group.ToUpperInvariant())) { $warnings.Add("Delivery group $group has no machines in the site.") }
    }

    # Group by delivery group (in the order of the file), then by name.
    $ordered = @($selected | Sort-Object { $_.order }, { $_.deliveryGroup }, { $_.name })
    $byGroup = [ordered]@{}
    foreach ($entry in $ordered) {
        if (-not $byGroup.Contains($entry.deliveryGroup)) { $byGroup[$entry.deliveryGroup] = [System.Collections.Generic.List[object]]::new() }
        $byGroup[$entry.deliveryGroup].Add($entry)
    }

    # The canary takes one machine from each group in turn.
    $canary = [System.Collections.Generic.List[object]]::new()
    $position = 0
    while ($canary.Count -lt $Maintenance.CanarySize -and $canary.Count -lt $ordered.Count) {
        foreach ($group in $byGroup.Values) {
            if ($position -lt $group.Count -and $canary.Count -lt $Maintenance.CanarySize) { $canary.Add($group[$position]) }
        }
        $position++
    }
    $inCanary = @{}
    foreach ($entry in $canary) { $inCanary[$entry.name] = $true }
    $rest = @($ordered | Where-Object { -not $inCanary.ContainsKey($_.name) })

    $waves = [System.Collections.Generic.List[object]]::new()
    if ($canary.Count -gt 0) {
        $waves.Add([ordered]@{ number = 1; kind = 'Canary'; failureBudget = 0; machines = [string[]]@($canary | ForEach-Object { $_.name }) })
    }
    for ($offset = 0; $offset -lt $rest.Count; $offset += $Maintenance.WaveSize) {
        $chunk = @($rest[$offset..([Math]::Min($offset + $Maintenance.WaveSize, $rest.Count) - 1)])
        $waves.Add([ordered]@{
                number = $waves.Count + 1
                kind = 'Wave'
                failureBudget = $Maintenance.FailureBudget
                machines = [string[]]@($chunk | ForEach-Object { $_.name })
            })
    }

    $waveOf = @{}
    foreach ($wave in $waves) { foreach ($name in $wave.machines) { $waveOf[$name] = $wave.number } }
    $planned = @($ordered | ForEach-Object {
            $_.Remove('order')
            $_.wave = $waveOf[$_.name]
            $_
        } | Sort-Object { $_.wave }, { $_.name })

    [ordered]@{
        kind = 'citrix-patch-waves-plan'
        schemaVersion = $script:SchemaVersion
        toolVersion = $script:ModuleVersion
        createdAt = Format-CpwDate (& $Provider.Now $Provider.State)
        provider = $Provider.Name
        simulation = [bool]$Provider.IsSimulation
        maintenance = ConvertTo-CpwMaintenanceSummary $Maintenance
        waves = $waves.ToArray()
        machines = $planned
        exclusions = @($exclusions | Sort-Object { $_.deliveryGroup }, { $_.name })
        warnings = $warnings.ToArray()
    }
}

