# Roadmap

Version 0.1.0 had the whole decision logic (plan, waves, drain, gate, window,
record) and proved it on a simulated site. Real execution is added one
provider action at a time, each with its own test, and nothing below is
promised until it is released.

## 0.2.0: restart a real site (released)

- Citrix actions through the Broker SDK: `Set-BrokerMachineMaintenanceMode`,
  `Send-BrokerSessionMessage`, `Get-BrokerSession` for the session count,
  `Stop-BrokerSession` for `forceLogoff`, and registration from
  `Get-BrokerMachine`, counted only after the machine was seen going down.
- Restart through `New-BrokerHostingPowerAction` when the machine has a
  hosting connection, `shutdown.exe` over WinRM otherwise (Remote PC Access).
- Service checks over WinRM, tested against a real Windows runner.
- Restart-only changes (`Invoke-CpwMaintenance -Execute`) on a real site, and
  the permissions in [release-verification.md](release-verification.md).
- A provider error fails only the machine it happened on.
- Still open: acceptance on a live site, which this repository cannot run.

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
