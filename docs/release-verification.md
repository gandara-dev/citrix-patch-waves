# Release Verification

## Public release gate

Every change must pass:

- Pester on Windows and Linux: validation, planner, engine, gate, window,
  journal, change record, the read-only Citrix provider with a mocked SDK, the
  scenarios end to end, and current demo data;
- PSScriptAnalyzer with no warnings or errors;
- the console tests in Node against the demo runs;
- JSON Schema validation of the sample maintenance file;
- a check from a fresh clone: `Invoke-PatchWaves.ps1 -Simulation` writes a
  change record for every scenario, and the console loads it through
  `Start-Console.ps1`.

These prove the decision logic and the console behave as documented on a
simulated site. They are not evidence about a real site, and in this version
the tool cannot change one.

## Environment acceptance gate

Before relying on a plan from a real site:

1. Run `Invoke-PatchWaves.ps1 -AdminAddress <controller> -PlanOnly` with a Read
   Only Administrator account.
2. For every target delivery group, compare the planned machines and the
   machines left out with Studio and with `Get-BrokerMachine`: pooled MCS and
   PVS machines, machines in maintenance mode, and unregistered machines must
   be left out with the right reason.
3. Check that the canary contains a machine from each delivery group and that
   no machine appears twice.
4. Review `plan.json` for host names before attaching it to a change: it
   contains machine, catalog, and delivery group names.

Before the first real change, once a release adds execution (see
[roadmap.md](roadmap.md)):

1. Use a non-production delivery group with two or three test machines and a
   window outside business hours.
2. Run with a canary of one and a failure budget of zero.
3. Confirm in Studio that every machine left maintenance mode, or stayed in it
   only when it failed, and that the change record matches what happened.
4. Repeat with a broken machine (for example, a stopped Broker Agent) and
   confirm the change stops after the canary.
