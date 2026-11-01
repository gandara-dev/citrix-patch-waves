# Citrix Patch Waves in Codespaces

This codespace has PowerShell 7 and the module. The console runs on port 8768
and opens by itself (see the **Ports** tab) with the demo runs. A first
simulated change (`wave-over-budget`) was already written to `artifacts/`.

Open a terminal and run PowerShell with `pwsh`.

## Plan and run a change

```powershell
./scripts/Invoke-PatchWaves.ps1 -Simulation -PlanOnly
./scripts/Invoke-PatchWaves.ps1 -Simulation -Scenario canary-failure -OutputDirectory ./artifacts/canary
```

Scenarios: `normal`, `canary-failure`, `wave-over-budget`, `window-closes`,
`force-logoff`. Download `artifacts/canary/run.json` (right-click it in the
Explorer) and choose **Open run.json** in the console, or open
`change-record.html` with the Live Preview.

## Break your own machines

```powershell
Import-Module ./src/CitrixPatchWaves/CitrixPatchWaves.psd1
$maintenance = Import-CpwMaintenance ./samples/lisbon-october.maintenance.json
$provider = New-CpwSimulationProvider -StartTime $maintenance.WindowStart -Failure @{
    LISW11FIN004 = 'NoRegistration'; LISW11FIN007 = 'ServiceStopped'
}
$run = Invoke-CpwMaintenance -Maintenance $maintenance -Provider $provider
$run.outcome; $run.stopReason
$run.machines | ForEach-Object { [pscustomobject]$_ } | Where-Object state -ne 'Completed' |
    Format-Table name, wave, state, detail -Wrap
```

Failure kinds: `PatchFails`, `NoRegistration`, `ServiceStopped`,
`UpdatesRemain`, `SessionsNeverEnd`, `LogoffFails`. Edit a copy of the sample
to change wave sizes, the budget, or the window, and validate it with
`Get-Content ./my.json -Raw | ConvertFrom-Json | Test-CpwMaintenance`.

## Tests

```powershell
Invoke-Pester ./tests
```

Planning against a real site needs a Delivery Controller or the Citrix Remote
PowerShell SDK, which this codespace does not have. Stop the codespace when you
are done so it does not use your Codespaces quota.
