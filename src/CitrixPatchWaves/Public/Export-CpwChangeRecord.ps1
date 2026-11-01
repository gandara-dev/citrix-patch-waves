function Export-CpwChangeRecord {
    <#
    .SYNOPSIS
    Writes the change record of a run: run.json, change-record.md, and change-record.html.

    .DESCRIPTION
    The record is written for the change advisory board and the next shift:
    the outcome in one sentence, the machines that need attention first, then
    the waves, every machine with its times, the machines left out and why, the
    settings used, and the full timeline. The HTML file prints on A4 or Letter.

    .EXAMPLE
    Export-CpwChangeRecord -Run $run -OutputDirectory ./artifacts
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Run,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $m = $Run.maintenance
    $outcome = Get-CpwOutcomeText $Run
    $providerText = if ($Run.simulation) { 'Simulation: no real machine was changed' } else { $Run.provider }
    $attention = @($Run.machines | Where-Object { $_.state -in 'Failed', 'NotDrained', 'Deferred' })
    $time = { param($Value) if ($Value) { ([string]$Value).Substring(11, 5) } else { '' } }
    $settings = @(
        @('Drain', "Up to $($m.drainTimeoutMinutes) minutes; " + $(if ($m.forceLogoff) { 'then sessions are logged off' } else { 'then the machine goes back into service unpatched' }))
        @('User message', $(if ($m.message) { "$($m.message.title): $($m.message.text)" } else { 'None' }))
        @('Windows updates', $(if (@($m.windowsUpdates).Count) { @($m.windowsUpdates) -join ', ' } else { 'Not installed' }))
        @('Applications', $(if (@($m.software).Count) { (@($m.software) | ForEach-Object { "$($_.name) ($($_.wingetId))" }) -join ', ' } else { 'None' }))
        @('Waves', "Canary of $($m.canarySize) (no failure allowed), then waves of $($m.waveSize) with a failure budget of $($m.failureBudget); $($m.concurrency) machines patched at a time")
        @('After the restart', "Registered within $($m.rebootTimeoutMinutes) minutes; services running: $(@($m.services) -join ', '); no requested update still applicable")
    )

    # ---------------------------------------------------------------- Markdown
    $md = [System.Text.StringBuilder]::new()
    $line = { param([string]$Text = '') [void]$md.AppendLine($Text) }
    $cell = { param($Value) ([string]$Value).Replace('|', '\|').Replace("`n", ' ') }
    & $line "# Change record: $($m.name)"
    & $line
    & $line '| | |'
    & $line '|---|---|'
    if ($m.change) { & $line "| Change | $(& $cell $m.change) |" }
    & $line "| Window | $($m.windowStart) to $($m.windowEnd) |"
    & $line "| Ran | $($Run.startedAt) to $($Run.finishedAt) |"
    & $line "| Provider | $(& $cell $providerText) |"
    & $line "| Tool | citrix-patch-waves $($Run.toolVersion) |"
    & $line
    & $line "**$(& $cell $outcome)**"
    & $line
    & $line '## Needs attention'
    & $line
    if ($attention.Count -eq 0) {
        & $line 'Nothing: every planned machine that started was patched and is back in service.'
    }
    else {
        & $line '| Machine | Result | In maintenance mode | Detail |'
        & $line '|---|---|---|---|'
        foreach ($machine in $attention) {
            & $line "| $($machine.name) | $($machine.state) | $(if ($machine.inMaintenanceMode) { 'Yes' } else { 'No' }) | $(& $cell $machine.detail) |"
        }
    }
    & $line
    & $line '## Waves'
    & $line
    & $line '| Wave | Kind | Started | Finished | Patched | Failed | Not drained | Deferred | Budget | Result |'
    & $line '|---|---|---|---|---|---|---|---|---|---|'
    foreach ($wave in $Run.waves) {
        & $line "| $($wave.number) | $($wave.kind) | $(& $time $wave.startedAt) | $(& $time $wave.finishedAt) | $($wave.completed) | $($wave.failed) | $($wave.notDrained) | $($wave.deferred) | $($wave.failureBudget) | $($wave.result) |"
    }
    & $line
    & $line '## Machines'
    & $line
    & $line 'Times are UTC.'
    & $line
    & $line '| Machine | Delivery group | Wave | Result | Sessions | Drained | Patched | Registered | Installed |'
    & $line '|---|---|---|---|---|---|---|---|---|'
    foreach ($machine in $Run.machines) {
        & $line "| $($machine.name) | $($machine.deliveryGroup) | $($machine.wave) | $($machine.state) | $($machine.sessionsAtDrain) | $(& $time $machine.drainedAt) | $(& $time $machine.patchFinishedAt) | $(& $time $machine.registeredAt) | $(@($machine.installed).Count) |"
    }
    & $line
    & $line '## Left out before the change'
    & $line
    if (@($Run.exclusions).Count -eq 0) {
        & $line 'None.'
    }
    else {
        & $line '| Machine | Delivery group | Reason |'
        & $line '|---|---|---|'
        foreach ($machine in $Run.exclusions) { & $line "| $($machine.name) | $($machine.deliveryGroup) | $(& $cell $machine.reason) |" }
    }
    foreach ($warning in @($Run.warnings)) { & $line; & $line "> $(& $cell $warning)" }
    & $line
    & $line '## Settings'
    & $line
    & $line '| | |'
    & $line '|---|---|'
    foreach ($setting in $settings) { & $line "| $($setting[0]) | $(& $cell $setting[1]) |" }
    & $line
    & $line '## Timeline'
    & $line
    & $line '| Time | Wave | Machine | Step | Detail |'
    & $line '|---|---|---|---|---|'
    foreach ($entry in $Run.events) {
        & $line "| $(& $time $entry.time) | $(if ($entry.wave) { $entry.wave }) | $($entry.machine) | $($entry.step) | $(& $cell $entry.detail) |"
    }

    # -------------------------------------------------------------------- HTML
    $e = { param($Value) [System.Net.WebUtility]::HtmlEncode([string]$Value) }
    $row = {
        param([object[]]$Cells, [string]$Class = '')
        $open = if ($Class) { '<tr class="' + (& $e $Class) + '">' } else { '<tr>' }
        $open + (($Cells | ForEach-Object { "<td>$(& $e $_)</td>" }) -join '') + '</tr>'
    }
    $head = { param([string[]]$Cells) '<tr>' + (($Cells | ForEach-Object { "<th>$(& $e $_)</th>" }) -join '') + '</tr>' }
    $status = switch ($Run.outcome) { 'Completed' { 'ok' } 'CompletedWithExceptions' { 'warn' } default { 'bad' } }
    $html = [System.Text.StringBuilder]::new()
    $add = { param([string]$Text) [void]$html.AppendLine($Text) }
    & $add '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
    & $add "<title>Change record: $(& $e $m.name)</title><style>"
    & $add 'body{font:13px/1.45 "Segoe UI",system-ui,sans-serif;color:#1d2733;max-width:1000px;margin:24px auto;padding:0 16px}'
    & $add 'h1{font-size:20px;margin:0 0 12px}h2{font-size:15px;margin:26px 0 8px;border-bottom:1px solid #d5dbe1;padding-bottom:4px}'
    & $add 'table{border-collapse:collapse;width:100%;margin-bottom:8px}th,td{text-align:left;vertical-align:top;padding:4px 8px;border-bottom:1px solid #e8ecf0;overflow-wrap:anywhere}th{background:#f5f7f9;font-weight:600}'
    & $add '.facts td:first-child{width:140px;color:#5a6878}.outcome{padding:10px 12px;border-radius:3px;font-weight:600;margin:14px 0}'
    & $add '.ok{background:#e6f4ec;color:#1d7a43}.warn{background:#fdf2e0;color:#8a5200}.bad{background:#fbe9e7;color:#b3261e}tr.Failed td{color:#b3261e}'
    & $add '.scroll{overflow-x:auto}@media print{body{margin:0;max-width:none}.outcome{border:1px solid currentColor}}</style></head><body>'
    & $add "<h1>Change record: $(& $e $m.name)</h1><table class=`"facts`">"
    if ($m.change) { & $add (& $row @('Change', $m.change)) }
    & $add (& $row @('Window', "$($m.windowStart) to $($m.windowEnd)"))
    & $add (& $row @('Ran', "$($Run.startedAt) to $($Run.finishedAt)"))
    & $add (& $row @('Provider', $providerText))
    & $add (& $row @('Tool', "citrix-patch-waves $($Run.toolVersion)"))
    & $add "</table><div class=`"outcome $status`">$(& $e $outcome)</div>"
    & $add '<h2>Needs attention</h2>'
    if ($attention.Count -eq 0) {
        & $add '<p>Nothing: every planned machine that started was patched and is back in service.</p>'
    }
    else {
        & $add ('<div class="scroll"><table>' + (& $head @('Machine', 'Result', 'In maintenance mode', 'Detail')))
        foreach ($machine in $attention) { & $add (& $row @($machine.name, $machine.state, $(if ($machine.inMaintenanceMode) { 'Yes' } else { 'No' }), $machine.detail) $machine.state) }
        & $add '</table></div>'
    }
    & $add ('<h2>Waves</h2><div class="scroll"><table>' + (& $head @('Wave', 'Kind', 'Started', 'Finished', 'Patched', 'Failed', 'Not drained', 'Deferred', 'Budget', 'Result')))
    foreach ($wave in $Run.waves) {
        & $add (& $row @($wave.number, $wave.kind, (& $time $wave.startedAt), (& $time $wave.finishedAt), $wave.completed, $wave.failed, $wave.notDrained, $wave.deferred, $wave.failureBudget, $wave.result))
    }
    & $add ('</table></div><h2>Machines</h2><p>Times are UTC.</p><div class="scroll"><table>' + (& $head @('Machine', 'Delivery group', 'Wave', 'Result', 'Sessions', 'Drained', 'Patched', 'Registered', 'Installed')))
    foreach ($machine in $Run.machines) {
        & $add (& $row @($machine.name, $machine.deliveryGroup, $machine.wave, $machine.state, $machine.sessionsAtDrain, (& $time $machine.drainedAt), (& $time $machine.patchFinishedAt), (& $time $machine.registeredAt), @($machine.installed).Count) $machine.state)
    }
    & $add '</table></div><h2>Left out before the change</h2>'
    if (@($Run.exclusions).Count -eq 0) { & $add '<p>None.</p>' }
    else {
        & $add ('<div class="scroll"><table>' + (& $head @('Machine', 'Delivery group', 'Reason')))
        foreach ($machine in $Run.exclusions) { & $add (& $row @($machine.name, $machine.deliveryGroup, $machine.reason)) }
        & $add '</table></div>'
    }
    foreach ($warning in @($Run.warnings)) { & $add "<p><strong>Warning:</strong> $(& $e $warning)</p>" }
    & $add '<h2>Settings</h2><table class="facts">'
    foreach ($setting in $settings) { & $add (& $row $setting) }
    & $add ('</table><h2>Timeline</h2><div class="scroll"><table>' + (& $head @('Time', 'Wave', 'Machine', 'Step', 'Detail')))
    foreach ($entry in $Run.events) { & $add (& $row @((& $time $entry.time), $(if ($entry.wave) { $entry.wave }), $entry.machine, $entry.step, $entry.detail)) }
    & $add '</table></div></body></html>'

    $json = Join-Path $OutputDirectory 'run.json'
    $markdown = Join-Path $OutputDirectory 'change-record.md'
    $page = Join-Path $OutputDirectory 'change-record.html'
    Set-Content -LiteralPath $json -Value ($Run | ConvertTo-Json -Depth 12) -Encoding utf8NoBOM
    Set-Content -LiteralPath $markdown -Value $md.ToString().TrimEnd() -Encoding utf8NoBOM
    Set-Content -LiteralPath $page -Value $html.ToString().TrimEnd() -Encoding utf8NoBOM
    Get-Item -LiteralPath $json, $markdown, $page
}
