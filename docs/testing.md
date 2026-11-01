# Testing Guide

Everything here runs without a Citrix site, Active Directory, or Windows
Update. The simulation provider is deterministic, so the same input always
gives the same run and the tests compare exact values.

## Pester

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path ./tests -CI -Output Detailed
```

`tests/CitrixPatchWaves.Tests.ps1` covers:

- the manifest and its version;
- every validation rule of the maintenance file, one case per rule;
- the planner: canary interleaving across delivery groups, wave sizes, and
  each exclusion reason;
- the engine: drain timeout, forced logoff (including sessions that survive
  it), concurrency, patch failure, missing registration, stopped service,
  updates still applicable, the failure gate, the window, and the journal;
- the change record files;
- the Citrix provider against a mocked Broker SDK and WinRM: planning, a
  restart-only change from drain to service check, hosting power actions for
  MCS and WinRM restarts for Remote PC Access, registration that only counts
  after the machine was seen going down, a refused restart, and the refusal
  to start a change that installs updates;
- a provider error on one machine, which fails that machine only;
- the demo data: `site/data` must match what `scripts/Update-DemoData.ps1`
  produces from the current engine.

Inject a failure on any simulated machine with `-Failure`:

```powershell
Import-Module ./src/CitrixPatchWaves/CitrixPatchWaves.psd1
$maintenance = Import-CpwMaintenance ./samples/lisbon-october.maintenance.json
$provider = New-CpwSimulationProvider -StartTime $maintenance.WindowStart -Failure @{
    LISW11FIN004 = 'NoRegistration'; LISW11ENG003 = 'ServiceStopped'
}
(Invoke-CpwMaintenance -Maintenance $maintenance -Provider $provider).totals
```

Failure kinds: `PatchFails`, `NoRegistration`, `ServiceStopped`,
`UpdatesRemain`, `SessionsNeverEnd`, `LogoffFails`.

`tests/WinRM.Tests.ps1` runs the provider's service checks over real WinRM
against the local machine. It is skipped where WinRM is not enabled; CI
enables PowerShell remoting on a Windows runner and requires it to pass.

## Console

```powershell
node --test tests/web/*.test.mjs
```

The Node tests replay every demo run and check that the replay ends exactly
where the engine ended, that intermediate moments are consistent, that a
stopped change marks later waves as not started, and that invalid files are
explained. Serve the page with `./scripts/Start-Console.ps1 -Open`.

## Demo data

After changing the engine, the simulation, or the sample:

```powershell
./scripts/Update-DemoData.ps1
```

Pester fails until the files in `site/data` are regenerated.

## Static analysis

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning,Error
```

CI also validates every file in `samples/` against
`schemas/maintenance.schema.json` and runs `Invoke-PatchWaves.ps1` for every
scenario, checking the outcome of each.
