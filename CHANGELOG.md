# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-01

### Added

- Maintenance file (schema version 1) with a window, target delivery groups
  and machines, wave sizes, concurrency, failure budget, drain timeout and
  user message, Windows Update categories, WinGet applications, reboot
  timeout, and the services to verify. `Test-CpwMaintenance` reports every
  problem with its JSON path; `schemas/maintenance.schema.json` describes the
  same shape for editors.
- `Get-CpwPlan`: a canary that takes machines from each delivery group in turn,
  fixed-size waves, and the machines left out with the reason (pooled MCS, PVS,
  already in maintenance mode, not registered, excluded).
- `Invoke-CpwMaintenance`: drain, patch, restart, registration, and service
  checks per wave, with a concurrency limit, a failure gate between waves, a
  hard stop at the end of the window, and a JSON Lines journal. Failed machines
  stay in maintenance mode; machines that do not drain go back into service.
  With `drain.forceLogoff`, sessions are logged off once, and a machine that
  still has sessions ten minutes later goes back into service unpatched.
- `Export-CpwChangeRecord`: `run.json`, `change-record.md`, and a printable
  `change-record.html`.
- Deterministic simulation of a 44-desktop site with injectable failures and
  five scenarios; a read-only Citrix provider that plans against a real site.
- Patch Waves Console: replays a run wave by wave in the browser, in the
  Citrix Studio style used by the other gandara-dev tools, and opens any
  `run.json`.
- GitHub Codespaces configuration, CI on Windows and Linux, and GitHub Pages
  deployment of the console.
