# Roadmap

Version 0.1.0 has the whole decision logic (plan, waves, drain, gate, window,
record) and proves it on a simulated site. The Citrix provider only reads.
Real execution is added one provider action at a time, each with its own test
against real Windows, and nothing below is promised until it is released.

## 0.2.0: change a real site

- Citrix actions through the Broker SDK: `Set-BrokerMachineMaintenanceMode`,
  `Send-BrokerSessionMessage`, `Get-BrokerSession` for the session count, and
  `Stop-BrokerSession` for `forceLogoff`; registration from
  `Get-BrokerMachine`.
- Restart through `New-BrokerHostingPowerAction` when the machine has a hosting
  connection, `Restart-Computer` over WinRM otherwise (Remote PC Access).
- Service checks over WinRM.
- `Invoke-CpwMaintenance -Execute` against the Citrix provider, with the exact
  Citrix role permissions listed in the docs. A Read Only Administrator stops
  being enough from this version on.

## 0.3.0: patch in place

- Windows Update through the Windows Update Agent API in a scheduled task on
  the VDA (remote sessions cannot install updates directly), with the
  categories from the maintenance file and the result codes in the record.
- WinGet upgrades for the listed applications, in machine scope.
- An integration test on GitHub's `windows-latest` runner, which is a real
  Windows machine: search for applicable updates, upgrade a WinGet package,
  and check a service, without a Citrix site.

## 0.4.0: operate it

- Resume from the journal after an interrupted run.
- A console view that follows a running change from its journal.

## Not planned

- Pooled MCS and PVS machines: the image is the unit of change there.
- Citrix Cloud (DaaS), until the on-premises path is accepted on a real site.
