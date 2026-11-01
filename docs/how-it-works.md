# How It Works

A change has four steps, each a public function of the `CitrixPatchWaves`
module. Every step takes a provider: the deterministic simulation
(`New-CpwSimulationProvider`) or the Citrix site (`New-CpwCitrixProvider`,
read-only in this version). The engine never calls Citrix or Windows directly;
it only calls the provider, which is what keeps the logic testable without a
site.

## 1. Read the maintenance file

`Import-CpwMaintenance` runs `Test-CpwMaintenance`, throws with every problem
and its JSON path when the file is invalid, and fills in the defaults. See
[maintenance-file.md](maintenance-file.md).

## 2. Plan

`Get-CpwPlan` lists the machines of the target delivery groups (plus
`target.include`) and changes nothing. A machine is left out, with the reason
in the plan, when:

| Reason | Why |
|---|---|
| It is in `target.exclude` | The operator said so |
| `ProvisioningType` is `PVS` | Update the vDisk instead |
| MCS with `AllocationType` `Random` (pooled) | Update the master image; MCS rolls it out |
| Already in maintenance mode | Someone put it there for a reason; the change must not put it back into service |
| Not registered | A machine that is broken before the change would be blamed on the patch |

The remaining machines are sorted by delivery group, in the order of the file,
then by name. The canary wave takes one machine from each group in turn until
it has `waves.canarySize` machines, so every group is tested before the rest.
The canary's failure budget is always zero. The other machines are cut into
waves of `waves.waveSize` with `waves.failureBudget`.

The plan also warns about delivery groups with no machines and included
machines that were not found.

## 3. Run

`Invoke-CpwMaintenance` handles one wave at a time. Against a real site it
refuses to start without `-Execute`; the simulation always runs.

```text
           ┌──────────── sessions end ─────────────┐
MaintenanceOn ─> Draining ─> Ready ─> Patching ─> Restarting ─> Verifying ─> Completed (back in service)
                    │          │          │             │             │
                    │          │          └─ error or   └─ no         └─ service stopped or
                    │          │             240 min       registration  updates still applicable
                    │          │                ▼          ▼             ▼
                    │          │              Failed (stays in maintenance mode)
                    │          └─ window closed ─> Deferred (back in service)
                    └─ drain timeout ─> NotDrained (back in service)
```

- **Drain.** Every machine of the wave goes into maintenance mode at once, so
  no new session lands on it. Machines with sessions get the optional message.
  When sessions are still open after `drain.timeoutMinutes`, the machine goes
  back into service unpatched (`NotDrained`), unless `drain.forceLogoff` is
  true: then the sessions are logged off once, and a machine that still has
  sessions ten minutes later goes back into service unpatched.
- **Patch.** At most `waves.concurrency` machines patch at the same time.
  A patch that has not finished after 240 minutes fails.
- **Restart and register.** After the patch the machine restarts; it must
  register with a Delivery Controller within `reboot.timeoutMinutes`.
- **Verify.** Every service in `verify.services` must be running, and when
  Windows Update is enabled no update from the requested categories may still
  be applicable. Only then does the machine leave maintenance mode.
- **Gate.** When a wave ends with more `Failed` machines than its budget, no
  further wave starts and their machines are `NotStarted`. `NotDrained` and
  `Deferred` do not count against the budget: they say nothing about the patch.
- **Window.** No wave starts and no machine starts patching after
  `window.end`. Machines already patching finish, restart, and are verified.

The engine polls every `waves.pollMinutes`. With the simulation, waiting moves
a virtual clock, so a whole window runs in about a second.

The outcome of the change is `Completed`, `CompletedWithExceptions` (some
machines failed or did not drain, within budget), `WindowClosed`, or
`Stopped`.

## 4. Record

`Export-CpwChangeRecord` writes, for the change advisory board and the next
shift:

- `run.json`: the whole run, the input of the console;
- `change-record.md` and `change-record.html` (prints on A4 or Letter): the
  outcome in one sentence, the machines that need attention first, the waves,
  every machine with its times, the machines left out and why, the settings,
  and the timeline.

With `-JournalPath`, `Invoke-CpwMaintenance` also appends every event to a
JSON Lines file as it happens, so an interrupted run still leaves a trace.

## The console

`site/` is a static page with no dependencies. It replays a `run.json` on a
clock: the tree lists the waves, all machines, the ones that need attention,
the ones left out, and the timeline; the list shows each machine's step at
that moment, and the details pane shows its timeline. The
replay logic (`site/lib/replay.js`) only reads the events recorded by the
engine; it does not re-implement the engine, so what the page shows is what
the run did.
