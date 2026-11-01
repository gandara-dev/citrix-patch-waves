import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { countsAt, formatTime, machineEvents, stateAt, timeBounds, validateRun } from '../../site/lib/replay.js';

const site = fileURLToPath(new URL('../../site/', import.meta.url));
const load = (path) => JSON.parse(readFileSync(site + path, 'utf8'));
const index = load('data/index.json');
const runs = Object.fromEntries(index.map((item) => [item.id, validateRun(load(item.file))]));

test('the index lists the five scenarios with the outcome of each run', () => {
  assert.deepEqual(index.map((item) => item.id), ['normal', 'canary-failure', 'wave-over-budget', 'window-closes', 'force-logoff']);
  for (const item of index) assert.equal(runs[item.id].outcome, item.outcome);
});

for (const item of index) {
  test(`${item.id}: the replay ends exactly where the engine ended`, () => {
    const run = runs[item.id];
    const end = stateAt(run, timeBounds(run).end);
    assert.equal(end.finished, true);
    for (const machine of run.machines) {
      const replayed = end.machines.find((entry) => entry.name === machine.name);
      assert.equal(replayed.state, machine.state, `${machine.name} state`);
      assert.equal(replayed.maintenance, machine.inMaintenanceMode, `${machine.name} maintenance mode`);
    }
    const counts = countsAt(end);
    assert.equal(counts.Completed, run.totals.completed);
    assert.equal(counts.Failed, run.totals.failed);
    assert.equal(counts.NotDrained, run.totals.notDrained);
    assert.equal(counts.Deferred, run.totals.deferred);
    assert.equal(counts.NotStarted, run.totals.notStarted);
    assert.equal(counts.inMaintenance, run.totals.leftInMaintenance);
    assert.equal(counts.active + counts.pending, 0);
    for (const wave of run.waves) {
      assert.equal(end.waves.find((entry) => entry.number === wave.number).state, wave.result, `wave ${wave.number}`);
    }
  });
}

test('at the start only the canary machines are in progress', () => {
  const run = runs.normal;
  const start = stateAt(run, timeBounds(run).start);
  const busy = start.machines.filter((machine) => machine.state !== 'Pending').map((machine) => machine.name);
  assert.deepEqual(busy.sort(), [...run.waves[0].machines].sort());
  assert.ok(start.machines.filter((machine) => busy.includes(machine.name)).every((machine) => machine.maintenance));
  assert.equal(start.waves[0].state, 'Running');
  assert.equal(start.finished, false);
});

test('mid-run a machine moves through the steps with its registration', () => {
  const run = runs.normal;
  const events = machineEvents(run, 'LISW11FIN001');
  const at = (step) => Date.parse(events.find((event) => event.step === step).time);
  const restarting = stateAt(run, at('Restarted'));
  const machine = restarting.machines.find((entry) => entry.name === 'LISW11FIN001');
  assert.equal(machine.state, 'Restarting');
  assert.equal(machine.registration, 'Unregistered');
  assert.equal(machine.maintenance, true);
  const done = stateAt(run, at('Completed')).machines.find((entry) => entry.name === 'LISW11FIN001');
  assert.equal(done.state, 'Completed');
  assert.equal(done.registration, 'Registered');
  assert.equal(done.maintenance, false);
});

test('a stopped change marks the later waves as not started when the gate closes', () => {
  const run = runs['canary-failure'];
  const stop = run.events.find((event) => event.step === 'Stopped');
  const before = stateAt(run, Date.parse(stop.time) - 60000);
  assert.equal(before.machines.find((entry) => entry.name === 'LISW11FIN002').state, 'Pending');
  const after = stateAt(run, Date.parse(stop.time));
  assert.equal(after.machines.find((entry) => entry.name === 'LISW11FIN002').state, 'NotStarted');
  assert.equal(after.waves[1].state, 'NotStarted');
});

test('validateRun explains what is wrong', () => {
  assert.throws(() => validateRun([]), /not a JSON object/);
  assert.throws(() => validateRun({ kind: 'citrix-catalog-baseline-report' }), /not a Citrix Patch Waves run/);
  assert.throws(() => validateRun({ ...runs.normal, schemaVersion: 2 }), /Unsupported schemaVersion 2/);
  assert.throws(() => validateRun({ ...runs.normal, events: undefined }), /no events/);
});

test('times are shown in UTC', () => {
  assert.equal(formatTime('2026-10-04T21:05:00Z'), '21:05');
});
