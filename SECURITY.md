# Security Policy

## Supported versions

Security fixes are applied to the latest released minor version. The project
is pre-1.0; review the changelog before upgrading.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub Private
Vulnerability Reporting for this repository. Include only a synthetic
reproduction: never real plans, run files, change records, host names, user
names, or credentials.

## Security boundaries

- In this version the Citrix provider only calls `Get-BrokerMachine`. Every
  action that would change a site throws, and `Invoke-CpwMaintenance` refuses a
  real provider without `-Execute`.
- The tool runs with the rights of the account that starts it; use a Citrix
  Read Only Administrator for planning.
- Plans, run files, journals, and change records contain machine, catalog, and
  delivery group names, session counts, and the user message. Store them with
  the change, as internal data.
- The console reads a local `run.json` in the browser, escapes every value,
  and makes no network request except loading the bundled demo runs.
- `Start-Console.ps1` listens on loopback only and serves `site/`.

## Secret handling

The project never stores credentials. Do not put passwords, tokens, or real
run files in the repository, issues, command history, or test fixtures.
