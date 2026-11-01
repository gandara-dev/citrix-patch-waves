// Rebuilds the state of every machine and wave at any moment of a run from
// the run's event list. The engine in the PowerShell module makes every
// decision; this file only replays what it recorded.

export const ACTIVE = ['Draining', 'Waiting', 'Patching', 'Restarting', 'Verifying'];
export const TERMINAL = ['Completed', 'Failed', 'NotDrained', 'Deferred', 'NotStarted'];

export const STATE_LABEL = {
  Pending: 'Pending',
  Draining: 'Draining',
  Waiting: 'Waiting to patch',
  Patching: 'Patching',
  Restarting: 'Restarting',
  Verifying: 'Checking',
  Completed: 'Completed',
  Failed: 'Failed',
  NotDrained: 'Not drained',
  Deferred: 'Deferred',
  NotStarted: 'Not started',
};

export const STEP_LABEL = {
  MaintenanceOn: 'Maintenance mode on',
  MaintenanceOff: 'Maintenance mode off',
  MessageSent: 'Message sent to users',
  ForcedLogoff: 'Sessions logged off',
  Drained: 'No sessions left',
  PatchStarted: 'Patching started',
  Patched: 'Patching finished',
  Restarted: 'Restarted',
  Registered: 'Registered with the Delivery Controller',
  Completed: 'Completed',
  Failed: 'Failed',
  NotDrained: 'Not drained',
  Deferred: 'Deferred',
  Started: 'Change started',
  WaveStarted: 'Wave started',
  WavePassed: 'Wave passed',
  Stopped: 'Change stopped',
  WaveDeferred: 'Wave deferred',
  Finished: 'Change finished',
};

const STEP_STATE = {
  MaintenanceOn: 'Draining',
  Drained: 'Waiting',
  PatchStarted: 'Patching',
  Restarted: 'Restarting',
  Registered: 'Verifying',
  Completed: 'Completed',
  Failed: 'Failed',
  NotDrained: 'NotDrained',
  Deferred: 'Deferred',
};

export function validateRun(run) {
  if (!run || typeof run !== 'object' || Array.isArray(run)) {
    throw new Error('The file is not a JSON object.');
  }
  if (run.kind !== 'citrix-patch-waves-run') {
    throw new Error('This is not a Citrix Patch Waves run (run.json from Export-CpwChangeRecord).');
  }
  if (run.schemaVersion !== 1) {
    throw new Error(`Unsupported schemaVersion ${run.schemaVersion}.`);
  }
  for (const key of ['maintenance', 'waves', 'machines', 'events', 'totals']) {
    if (run[key] == null) throw new Error(`The run has no ${key}.`);
  }
  if (Number.isNaN(Date.parse(run.startedAt)) || Number.isNaN(Date.parse(run.finishedAt))) {
    throw new Error('The run has no valid start and finish time.');
  }
  return run;
}

export function timeBounds(run) {
  return { start: Date.parse(run.startedAt), end: Date.parse(run.finishedAt) };
}

export function stateAt(run, time) {
  const machines = new Map(run.machines.map((machine) => [machine.name, {
    name: machine.name,
    deliveryGroup: machine.deliveryGroup,
    wave: machine.wave,
    state: 'Pending',
    maintenance: false,
    registration: 'Registered',
    sessions: null,
    since: null,
    detail: null,
  }]));
  const waves = new Map(run.waves.map((wave) => [wave.number, {
    number: wave.number,
    kind: wave.kind,
    failureBudget: wave.failureBudget,
    machines: wave.machines,
    state: 'Pending',
  }]));
  let last = null;

  for (const event of run.events) {
    if (Date.parse(event.time) > time) break;
    last = event;
    const machine = event.machine ? machines.get(event.machine) : null;
    if (machine) {
      if (event.step === 'MaintenanceOn') {
        machine.maintenance = true;
        machine.sessions = run.machines.find((item) => item.name === machine.name)?.sessionsAtDrain ?? null;
      }
      if (event.step === 'MaintenanceOff') machine.maintenance = false;
      if (event.step === 'Drained' || event.step === 'ForcedLogoff') machine.sessions = 0;
      if (event.step === 'Restarted') machine.registration = 'Unregistered';
      if (event.step === 'Registered') machine.registration = 'Registered';
      const next = STEP_STATE[event.step];
      if (next && !(event.step === 'MaintenanceOn' && machine.state !== 'Pending')) {
        machine.state = next;
        machine.since = event.time;
        if (TERMINAL.includes(next)) machine.detail = event.detail;
      }
      continue;
    }
    const wave = waves.get(event.wave);
    if (event.step === 'WaveStarted' && wave) wave.state = 'Running';
    if (event.step === 'WavePassed' && wave) wave.state = 'Passed';
    if (event.step === 'WaveDeferred' && wave) {
      wave.state = 'Deferred';
      for (const name of wave.machines) {
        const item = machines.get(name);
        item.state = 'Deferred';
        item.since = event.time;
        item.detail = 'The window closed before this wave started.';
      }
    }
    if (event.step === 'Stopped' && wave) {
      wave.state = 'Stopped';
      for (const other of waves.values()) {
        if (other.number > wave.number) {
          other.state = 'NotStarted';
          for (const name of other.machines) {
            machines.get(name).state = 'NotStarted';
            machines.get(name).since = event.time;
          }
        }
      }
    }
  }

  return {
    time,
    finished: last?.step === 'Finished',
    machines: [...machines.values()],
    waves: [...waves.values()],
  };
}

export function countsAt(snapshot) {
  const counts = { total: snapshot.machines.length, pending: 0, active: 0, inMaintenance: 0 };
  for (const state of TERMINAL) counts[state] = 0;
  for (const machine of snapshot.machines) {
    if (machine.state === 'Pending') counts.pending += 1;
    else if (ACTIVE.includes(machine.state)) counts.active += 1;
    else counts[machine.state] += 1;
    if (machine.maintenance) counts.inMaintenance += 1;
  }
  return counts;
}

export function machineEvents(run, name) {
  return run.events.filter((event) => event.machine === name);
}

export function formatTime(value) {
  const date = new Date(value);
  return `${String(date.getUTCHours()).padStart(2, '0')}:${String(date.getUTCMinutes()).padStart(2, '0')}`;
}
