# Release Verification

## Public release gate

Every change must pass:

- Pester on Windows and Linux: validation, planner, engine, gate, window,
  journal, change record, the Citrix provider with a mocked Broker SDK and
  WinRM, the scenarios end to end, and current demo data;
- the provider's service checks over real WinRM on a Windows runner;
- PSScriptAnalyzer with no warnings or errors;
- the console tests in Node against the demo runs;
- JSON Schema validation of every sample maintenance file;
- a check from a fresh clone: `Invoke-PatchWaves.ps1 -Simulation` writes a
  change record for every scenario, and the console loads it through
  `Start-Console.ps1`.

These prove the decision logic and the console behave as documented on a
simulated site, and that the Citrix provider makes the documented SDK calls.
They are not evidence about a real site: the gate below is.

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

Before the first real change (restart-only in this version):

1. Give the account that runs the change a custom Citrix role scoped to the
   target delivery groups, with Read access plus the Delivery Group
   permissions to change machine maintenance mode, perform power operations
   on desktop machines, and perform session management (messages, and logoff
   when `forceLogoff` is on). Check the exact names in Studio's role editor
   for your version.
2. For Remote PC Access machines and for the service checks, the account
   must reach every VDA over WinRM (TCP 5985): a member of Remote Management
   Users can read services; restarting a Remote PC Access machine needs local
   administrator rights.
3. Use a non-production delivery group with two or three test machines, a
   window outside business hours, a canary of one, and a failure budget of
   zero. Start the run inside the window; the engine refuses to start before
   it.
4. Confirm in Studio that every machine left maintenance mode, or stayed in it
   only when it failed, and that the change record matches what happened.
5. Repeat with a broken machine (for example, a stopped Broker Agent) and
   confirm the change stops after the canary with that machine still in
   maintenance mode.
