# Citrix Patch Waves

[![CI](https://github.com/gandara-dev/citrix-patch-waves/actions/workflows/ci.yml/badge.svg)](https://github.com/gandara-dev/citrix-patch-waves/actions/workflows/ci.yml)
[![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-5391FE.svg)](https://learn.microsoft.com/powershell/)
[![License: PolyForm Shield 1.0.0](https://img.shields.io/badge/License-PolyForm%20Shield%201.0.0-lightgrey.svg)](LICENSE)

Patches Citrix VDAs in place, in waves, the way a careful administrator does it
by hand: a small canary first, then fixed-size waves. For every wave the
machines go into maintenance mode, users get a message, the engine waits for
the sessions to end, patches Windows and the listed applications, restarts,
waits for the VDA to register again, and checks the services. A wave with more
failures than its budget stops the change, and nothing starts after the
maintenance window closes. Every run ends with a change record for the CAB and
the next shift.

> Version 0.1.0 plans against a real site but only runs a change against the
> built-in simulation. The Citrix provider is read-only; see
> [docs/roadmap.md](docs/roadmap.md) for what real execution still needs.

**[Open the demo console](https://gandara-dev.github.io/citrix-patch-waves/)**
· or run the module in your browser:
[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/gandara-dev/citrix-patch-waves?quickstart=1)

## Why

Pooled MCS and PVS desktops are patched by updating the image; the rollout is
the platform's job. Persistent MCS desktops, Remote PC Access machines, and
manually provisioned VDAs are patched in place, usually with a script that
reboots everything at 22:00 and a morning spent finding the machines that did
not come back. This project makes that change predictable: the plan is
reviewed before the window, one bad patch stops at the canary, and the record
says exactly which machines need attention.

## How it works

```text
maintenance.json ──> Import-CpwMaintenance ──> Get-CpwPlan ──> Invoke-CpwMaintenance ──> Export-CpwChangeRecord
 (window, target,     (validates, applies        (waves, left-out     (drain, patch, restart,     (run.json, change-record.md,
  waves, drain,        defaults)                  machines and why)    register, verify, gate)     change-record.html, journal)
  patch, verify)
```

The planner leaves out machines it should not touch and says why: pooled MCS
and PVS machines (update the image instead), machines already in maintenance
mode, machines that are not registered before the change, and explicit
exclusions. The canary takes machines from each delivery group in turn and has
a failure budget of zero. See [docs/how-it-works.md](docs/how-it-works.md).

| Machine ends as | Meaning | Left in maintenance mode |
|---|---|---|
| `Completed` | Patched, registered, services running, no requested update left | No |
| `Failed` | Patch error, no registration after the restart, a stopped service, or updates still applicable | **Yes**, for investigation |
| `NotDrained` | Sessions did not end within the drain timeout (or survived a forced logoff) | No, back in service unpatched |
| `Deferred` | The window closed before the machine or its wave started | No |
| `NotStarted` | An earlier wave went over its failure budget | No |

## Try it without a Citrix site

Requirements: PowerShell 7.2 or newer.

```powershell
git clone https://github.com/gandara-dev/citrix-patch-waves.git
cd citrix-patch-waves
./scripts/Invoke-PatchWaves.ps1 -Simulation -PlanOnly
./scripts/Invoke-PatchWaves.ps1 -Simulation -Scenario wave-over-budget -OutputDirectory ./artifacts
./scripts/Start-Console.ps1 -Open
```

The simulated site has 44 desktops in three delivery groups and a virtual
clock, so a six-hour window runs in about a second and the same input always
gives the same run. Five scenarios ship with it:

| Scenario | What happens |
|---|---|
| `normal` | Every wave passes; three machines keep a session past the 60-minute drain and go back unpatched |
| `canary-failure` | Patching fails on the first canary machine; the change stops before wave 2 |
| `wave-over-budget` | Two machines fail in wave 2 with a budget of 1; waves 3 to 5 never start |
| `window-closes` | A three-hour window; the waves that do not fit are deferred |
| `force-logoff` | Sessions still open after the drain are logged off and every machine is patched |

Open `./artifacts/change-record.html` for the record, or load
`./artifacts/run.json` in the console with **Open run.json** to replay it.

## Plan against a real site

On a Delivery Controller, or a management machine with the Citrix Remote
PowerShell SDK:

```powershell
./scripts/Invoke-PatchWaves.ps1 -MaintenancePath ./maintenance.json -AdminAddress ddc01.corp.example.test -PlanOnly
```

This only calls `Get-BrokerMachine`; a Citrix Read Only Administrator is
enough. It writes `plan.json` and prints the waves and the machines left out.
Any attempt to change a real site throws. The maintenance file format is in
[docs/maintenance-file.md](docs/maintenance-file.md), with a JSON Schema in
`schemas/maintenance.schema.json`.

## Test

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path ./tests -CI -Output Detailed
node --test tests/web/*.test.mjs
```

CI runs Pester on Windows and Linux, PSScriptAnalyzer, the console tests, a
JSON Schema check of the sample, and every scenario end to end. See
[docs/testing.md](docs/testing.md).

## Documentation

- [How it works](docs/how-it-works.md)
- [Maintenance file](docs/maintenance-file.md)
- [Roadmap](docs/roadmap.md)
- [Testing guide](docs/testing.md)
- [Release verification](docs/release-verification.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

## Current scope

Version `0.1.0` targets VDAs on on-premises Citrix Virtual Apps and Desktops.
It plans against a real site and runs changes only in the simulation, which
models single-session desktops. It does not patch Delivery Controllers or
StoreFront, does not read Citrix Cloud (DaaS), and does not schedule itself;
run it from the job scheduler you already trust. These are explicit limits,
not implicit promises.

## License

[PolyForm Shield 1.0.0](LICENSE). You may use, study, and modify this project,
including inside your organization, but not to offer a product that competes
with it. This is a source-available license, not an OSI-approved open-source
license.
