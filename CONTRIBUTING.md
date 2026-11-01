# Contributing

Contributions should keep the decision logic in the PowerShell module,
deterministic, and testable without a Citrix site.

## Development workflow

1. Create a focused branch from `main`.
2. Keep every example, fixture, and screenshot synthetic.
3. Add or update Pester tests for behavioral changes. A new way for a machine
   to fail needs a simulated failure kind and a test that uses it.
4. Run `./scripts/Update-DemoData.ps1` after changing the engine, the
   simulation, or the sample maintenance file.
5. Run Pester, the Node tests, and PSScriptAnalyzer.
6. Update the documentation and the changelog when behavior changes.
7. Open a pull request explaining the change and how it was validated.

Use English for code, documentation, issues, and commit messages.

## Rules for the engine and the providers

- The engine only talks to a provider. A new Citrix or Windows call goes into
  a provider action, with the same signature in the simulation.
- A machine that failed stays in maintenance mode; every other machine leaves
  it. Keep that invariant and its tests.
- The console replays recorded events; it never decides anything the engine
  did not record.

## Pull request checklist

- [ ] No real plan, run file, change record, or customer name is included.
- [ ] Pester passes on PowerShell 7.
- [ ] `node --test tests/web/*.test.mjs` passes.
- [ ] PSScriptAnalyzer reports no warnings or errors.
- [ ] The demo data is current.
- [ ] Documentation and `CHANGELOG.md` reflect the change.

Security reports must follow `SECURITY.md`, not the public issue tracker.
