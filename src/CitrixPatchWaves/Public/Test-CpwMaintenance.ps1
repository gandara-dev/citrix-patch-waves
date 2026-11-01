$script:UpdateCategories = @('Critical Updates', 'Security Updates', 'Update Rollups', 'Updates', 'Definition Updates')

function Test-CpwMaintenance {
    <#
    .SYNOPSIS
    Validates a maintenance definition and returns every problem found.

    .DESCRIPTION
    Returns one object per problem with the JSON path and a message. An empty
    result means the definition is valid. The rules are listed in
    docs/maintenance-file.md.

    .EXAMPLE
    Get-Content ./samples/lisbon-october.maintenance.json -Raw | ConvertFrom-Json | Test-CpwMaintenance
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        $InputObject
    )

    process {
        $problems = [System.Collections.Generic.List[object]]::new()
        $add = { param($Path, $Message) $problems.Add([pscustomobject]@{ Path = $Path; Message = $Message }) }

        if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject -is [array]) {
            & $add '' 'The maintenance definition must be a JSON object.'
            return $problems.ToArray()
        }

        if ((Get-CpwValue $InputObject 'schemaVersion') -ne 1) {
            & $add 'schemaVersion' 'Only schemaVersion 1 is supported.'
        }

        $name = Get-CpwValue $InputObject 'name'
        if ($name -isnot [string] -or $name.Trim().Length -lt 3 -or $name.Length -gt 120) {
            & $add 'name' 'Use a name of 3 to 120 characters.'
        }
        $change = Get-CpwValue $InputObject 'change'
        if ($null -ne $change -and ($change -isnot [string] -or $change -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$')) {
            & $add 'change' 'Use a change reference of up to 40 letters, digits, dots, hyphens, or underscores.'
        }

        # ------------------------------------------------------------ window
        $window = Get-CpwValue $InputObject 'window'
        if ($null -eq $window) {
            & $add 'window' 'The maintenance window is required.'
        }
        else {
            $start = ConvertTo-CpwDate (Get-CpwValue $window 'start')
            $end = ConvertTo-CpwDate (Get-CpwValue $window 'end')
            if ($null -eq $start) { & $add 'window.start' 'Use an ISO 8601 time with a UTC offset, for example 2026-10-04T21:00:00Z.' }
            if ($null -eq $end) { & $add 'window.end' 'Use an ISO 8601 time with a UTC offset, for example 2026-10-05T03:00:00Z.' }
            if ($null -ne $start -and $null -ne $end) {
                $hours = ($end - $start).TotalHours
                if ($hours -le 0) { & $add 'window.end' 'The window must end after it starts.' }
                elseif ($hours -gt 72) { & $add 'window.end' 'The window cannot be longer than 72 hours.' }
            }
        }

        # ------------------------------------------------------------ target
        $target = Get-CpwValue $InputObject 'target'
        if ($null -eq $target) {
            & $add 'target' 'The target is required.'
        }
        else {
            $groups = @(Get-CpwList $target 'deliveryGroups')
            $include = @(Get-CpwList $target 'include')
            $exclude = @(Get-CpwList $target 'exclude')
            if ($groups.Count + $include.Count -eq 0) {
                & $add 'target' 'Name at least one delivery group or machine.'
            }
            for ($index = 0; $index -lt $groups.Count; $index++) {
                if ($groups[$index] -isnot [string] -or $groups[$index].Trim().Length -eq 0 -or $groups[$index].Length -gt 64) {
                    & $add "target.deliveryGroups[$index]" 'Use a delivery group name of 1 to 64 characters.'
                }
            }
            foreach ($list in @(@{ Name = 'include'; Items = $include }, @{ Name = 'exclude'; Items = $exclude })) {
                for ($index = 0; $index -lt $list.Items.Count; $index++) {
                    if ($list.Items[$index] -isnot [string] -or $list.Items[$index] -notmatch '^([A-Za-z0-9-]{1,15}\\)?[A-Za-z0-9-]{1,15}(\.[A-Za-z0-9-]+)*$') {
                        & $add "target.$($list.Name)[$index]" 'Use a machine name such as LISW11FIN001 or CORP\LISW11FIN001.'
                    }
                }
            }
        }

        # ------------------------------------------------------------ waves
        $waves = Get-CpwValue $InputObject 'waves'
        $ranges = [ordered]@{
            canarySize = @(0, 50); waveSize = @(1, 500); concurrency = @(1, 50); failureBudget = @(0, 500); pollMinutes = @(1, 30)
        }
        foreach ($key in $ranges.Keys) {
            if (Test-CpwHasValue $waves $key) {
                $value = Get-CpwValue $waves $key
                if (-not (Test-CpwInteger $value $ranges[$key][0] $ranges[$key][1])) {
                    & $add "waves.$key" "Use a whole number from $($ranges[$key][0]) to $($ranges[$key][1])."
                }
            }
        }
        $waveSize = Get-CpwValue $waves 'waveSize' 10
        $budget = Get-CpwValue $waves 'failureBudget' 0
        if ((Test-CpwInteger $waveSize 1 500) -and (Test-CpwInteger $budget 0 500) -and $budget -ge $waveSize) {
            & $add 'waves.failureBudget' 'The failure budget must be smaller than the wave size, or a wave could fail completely and still pass.'
        }

        # ------------------------------------------------------------ drain
        $drain = Get-CpwValue $InputObject 'drain'
        if ((Test-CpwHasValue $drain 'timeoutMinutes') -and -not (Test-CpwInteger (Get-CpwValue $drain 'timeoutMinutes') 0 1440)) {
            & $add 'drain.timeoutMinutes' 'Use a whole number of minutes from 0 to 1440.'
        }
        if ((Test-CpwHasValue $drain 'forceLogoff') -and (Get-CpwValue $drain 'forceLogoff') -isnot [bool]) {
            & $add 'drain.forceLogoff' 'Use true or false.'
        }
        $message = Get-CpwValue $drain 'message'
        if ($null -ne $message) {
            $enabled = Get-CpwValue $message 'enabled' $false
            if ($enabled -isnot [bool]) { & $add 'drain.message.enabled' 'Use true or false.' }
            if ($enabled -eq $true) {
                $title = Get-CpwValue $message 'title'
                $text = Get-CpwValue $message 'text'
                if ($title -isnot [string] -or $title.Trim().Length -eq 0 -or $title.Length -gt 64) {
                    & $add 'drain.message.title' 'Use a title of 1 to 64 characters.'
                }
                if ($text -isnot [string] -or $text.Trim().Length -eq 0 -or $text.Length -gt 1000) {
                    & $add 'drain.message.text' 'Use a message of 1 to 1000 characters.'
                }
            }
        }

        # ------------------------------------------------------------ patch
        $patch = Get-CpwValue $InputObject 'patch'
        $windowsUpdates = Get-CpwValue $patch 'windowsUpdates'
        $updatesEnabled = Get-CpwValue $windowsUpdates 'enabled' $true
        if ($updatesEnabled -isnot [bool]) { & $add 'patch.windowsUpdates.enabled' 'Use true or false.' }
        $categories = @(Get-CpwList $windowsUpdates 'categories')
        for ($index = 0; $index -lt $categories.Count; $index++) {
            if ($script:UpdateCategories -notcontains $categories[$index]) {
                & $add "patch.windowsUpdates.categories[$index]" "Use one of: $($script:UpdateCategories -join ', ')."
            }
        }
        $software = @(Get-CpwList $patch 'software')
        $seen = @{}
        for ($index = 0; $index -lt $software.Count; $index++) {
            $item = $software[$index]
            $itemName = Get-CpwValue $item 'name'
            $wingetId = Get-CpwValue $item 'wingetId'
            if ($itemName -isnot [string] -or $itemName.Trim().Length -eq 0 -or $itemName.Length -gt 80) {
                & $add "patch.software[$index].name" 'Use a name of 1 to 80 characters.'
            }
            if ($wingetId -isnot [string] -or $wingetId -notmatch '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$') {
                & $add "patch.software[$index].wingetId" 'Use a WinGet package ID such as Google.Chrome.'
            }
            elseif ($seen.ContainsKey($wingetId.ToLowerInvariant())) {
                & $add "patch.software[$index].wingetId" "$wingetId is listed twice."
            }
            else {
                $seen[$wingetId.ToLowerInvariant()] = $true
            }
        }
        if ($updatesEnabled -eq $false -and $software.Count -eq 0) {
            & $add 'patch' 'Enable Windows updates or list at least one application; otherwise there is nothing to patch.'
        }

        # ------------------------------------------------------------ reboot and verify
        $reboot = Get-CpwValue $InputObject 'reboot'
        if ((Test-CpwHasValue $reboot 'timeoutMinutes') -and -not (Test-CpwInteger (Get-CpwValue $reboot 'timeoutMinutes') 5 240)) {
            & $add 'reboot.timeoutMinutes' 'Use a whole number of minutes from 5 to 240.'
        }
        $verify = Get-CpwValue $InputObject 'verify'
        $services = @(Get-CpwList $verify 'services')
        for ($index = 0; $index -lt $services.Count; $index++) {
            if ($services[$index] -isnot [string] -or $services[$index] -notmatch '^[A-Za-z0-9_.-]{1,80}$') {
                & $add "verify.services[$index]" 'Use a Windows service name such as BrokerAgent.'
            }
        }

        return $problems.ToArray()
    }
}
