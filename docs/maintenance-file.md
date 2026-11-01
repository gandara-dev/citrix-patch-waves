# Maintenance File

One JSON file describes one change. `Test-CpwMaintenance` enforces the rules
below and returns every problem with its JSON path;
`schemas/maintenance.schema.json` describes the same shape for editors and CI.
Unknown properties are ignored.

```json
{
  "schemaVersion": 1,
  "name": "2026-10 patching: Lisbon persistent and Remote PC desktops",
  "change": "CHG-2026-1004",
  "window": { "start": "2026-10-04T21:00:00Z", "end": "2026-10-05T03:00:00Z" },
  "target": {
    "deliveryGroups": ["DG-LIS-W11-DED-FINANCE", "DG-LIS-W11-RPC-ENGINEERING"],
    "include": [],
    "exclude": ["LISW11FIN011"]
  },
  "waves": { "canarySize": 2, "waveSize": 10, "concurrency": 5, "failureBudget": 1, "pollMinutes": 1 },
  "drain": {
    "timeoutMinutes": 60,
    "forceLogoff": false,
    "message": { "enabled": true, "title": "Planned maintenance", "text": "..." }
  },
  "patch": {
    "windowsUpdates": { "enabled": true, "categories": ["Security Updates", "Critical Updates"] },
    "software": [{ "name": "Google Chrome", "wingetId": "Google.Chrome" }]
  },
  "reboot": { "timeoutMinutes": 30 },
  "verify": { "services": ["BrokerAgent"] }
}
```

## Fields

| Path | Required | Default | Rule |
|---|---|---|---|
| `schemaVersion` | yes | | `1` |
| `name` | yes | | 3 to 120 characters |
| `change` | no | | Change reference: up to 40 letters, digits, `.`, `-`, `_` |
| `window.start`, `window.end` | yes | | ISO 8601 with a UTC offset; the end is after the start and at most 72 hours later |
| `target.deliveryGroups` | one of the two | `[]` | Delivery group names, 1 to 64 characters |
| `target.include` | one of the two | `[]` | Machines added outside the groups: `NAME` or `DOMAIN\NAME` |
| `target.exclude` | no | `[]` | Machines never touched, same format |
| `waves.canarySize` | no | `1` | 0 to 50; `0` skips the canary |
| `waves.waveSize` | no | `10` | 1 to 500 |
| `waves.concurrency` | no | `5` | 1 to 50 machines patching at once within a wave |
| `waves.failureBudget` | no | `0` | 0 to 500, and smaller than `waveSize` |
| `waves.pollMinutes` | no | `1` | 1 to 30 |
| `drain.timeoutMinutes` | no | `60` | 0 to 1440 |
| `drain.forceLogoff` | no | `false` | Log off sessions still open after the drain timeout |
| `drain.message.enabled` | no | `false` | When true, `title` (1 to 64) and `text` (1 to 1000) are required |
| `patch.windowsUpdates.enabled` | no | `true` | |
| `patch.windowsUpdates.categories` | no | Security and Critical Updates | `Critical Updates`, `Security Updates`, `Update Rollups`, `Updates`, `Definition Updates` |
| `patch.software[].name` | | | 1 to 80 characters |
| `patch.software[].wingetId` | | | A WinGet package ID, listed once |
| `reboot.timeoutMinutes` | no | `30` | 5 to 240 minutes to register after the restart |
| `verify.services` | no | `["BrokerAgent"]` | Windows service names; `[]` checks none |

With Windows Update off and no application listed, the change is a rolling
restart: each machine is drained, restarted, and verified, with the same waves,
gate, and window. This is the only kind of change the Citrix provider runs on a
real site in this version:

```json
"patch": { "windowsUpdates": { "enabled": false }, "software": [] }
```

## Choosing the numbers

- **Canary.** Two machines from different delivery groups catch a bad patch for
  each image before it reaches the rest.
- **Failure budget.** A budget of 1 in waves of 10 tolerates one broken
  machine per wave; a second one stops the change. A budget equal to the wave
  size is rejected because a wave could fail completely and still pass.
- **Drain.** Persistent desktops often keep disconnected sessions. A long drain
  without `forceLogoff` returns those machines unpatched, which the record
  lists; `forceLogoff` patches them at the cost of the users' open work.
- **Window.** Leave time for the last wave's restarts: machines that started
  patching before the end finish after it.

Validate a file without running anything:

```powershell
Import-Module ./src/CitrixPatchWaves/CitrixPatchWaves.psd1
Get-Content ./maintenance.json -Raw | ConvertFrom-Json | Test-CpwMaintenance
```
