import {
  ACTIVE,
  STATE_LABEL,
  STEP_LABEL,
  countsAt,
  formatTime,
  machineEvents,
  stateAt,
  timeBounds,
  validateRun,
} from './lib/replay.js';

const $ = (selector) => document.querySelector(selector);

let scenarios = [];
let run = null;
let bounds = { start: 0, end: 0 };
let time = 0;
let snapshot = null;
let node = 'overview';
let selected = null;
let timer = null;

// ------------------------------------------------------------------ helpers

function e(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function stateClass(state) {
  if (ACTIVE.includes(state)) return 'active';
  if (state === 'Completed' || state === 'Passed') return 'ok';
  if (state === 'Failed' || state === 'Stopped') return 'bad';
  if (state === 'NotDrained' || state === 'Deferred') return 'warn';
  return '';
}

function stateCell(state, label = STATE_LABEL[state] ?? state) {
  return `<span class="state ${stateClass(state)}">${e(label)}</span>`;
}

function props(items) {
  return `<dl class="props">${items.map(([key, value]) => `<div><dt>${e(key)}</dt><dd>${value}</dd></div>`).join('')}</dl>`;
}

function grid(columns, rows, { key, onSelect, empty = 'Nothing to show.' } = {}) {
  if (!rows.length) return `<p class="empty">${e(empty)}</p>`;
  const head = columns.map((column) => `<th class="${column.num ? 'num' : ''}">${e(column.label)}</th>`).join('');
  const body = rows.map((row) => {
    const id = key ? row[key] : null;
    const attributes = onSelect ? ` class="selectable" data-key="${e(id)}" tabindex="0" aria-selected="${id === selected}"` : '';
    const cells = columns.map((column) => `<td class="${column.num ? 'num' : ''}${column.wrap ? ' wrap' : ''}">${column.render ? column.render(row) : e(row[column.key])}</td>`).join('');
    return `<tr${attributes}>${cells}</tr>`;
  }).join('');
  return `<table class="grid"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function bindRows(container, onSelect) {
  for (const row of container.querySelectorAll('tr.selectable')) {
    const choose = () => onSelect(row.dataset.key);
    row.addEventListener('click', choose);
    row.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        choose();
      }
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        const next = event.key === 'ArrowDown' ? row.nextElementSibling : row.previousElementSibling;
        if (next) {
          onSelect(next.dataset.key);
          container.querySelector(`tr[data-key="${CSS.escape(next.dataset.key)}"]`)?.focus();
        }
      }
    });
  }
}

function outcomeText() {
  const t = run.totals;
  const patched = `${t.completed} of ${t.planned} machines patched`;
  switch (run.outcome) {
    case 'Completed': return [`Completed: ${patched}.`, 'ok'];
    case 'CompletedWithExceptions': {
      const parts = [];
      if (t.failed) parts.push(`${t.failed} failed and left in maintenance mode`);
      if (t.notDrained) parts.push(`${t.notDrained} returned to service unpatched because sessions did not end`);
      return [`Completed with exceptions: ${patched}; ${parts.join('; ')}.`, 'warn'];
    }
    case 'Stopped': return [`Stopped: ${patched}. ${run.stopReason}`, 'bad'];
    case 'WindowClosed': return [`Window closed: ${patched}; ${t.deferred} deferred to the next window.`, 'warn'];
    default: return [run.outcome, ''];
  }
}

// ------------------------------------------------------------------ views

const machineColumns = [
  { label: 'Machine', key: 'name' },
  { label: 'Delivery group', key: 'deliveryGroup' },
  { label: 'Wave', key: 'wave', num: true },
  { label: 'State', render: (row) => stateCell(row.state) },
  { label: 'Maintenance mode', render: (row) => (row.maintenance ? 'On' : '<span class="muted">Off</span>') },
  { label: 'Registration', render: (row) => (row.registration === 'Registered' ? 'Registered' : `<span class="state warn">${e(row.registration)}</span>`) },
  { label: 'Sessions', render: (row) => (row.sessions == null ? '<span class="muted">-</span>' : e(row.sessions)), num: true },
  { label: 'Since', render: (row) => (row.since ? formatTime(row.since) : ''), num: true },
];

function waveRows() {
  return snapshot.waves.map((wave) => {
    const machines = snapshot.machines.filter((machine) => machine.wave === wave.number);
    const count = (state) => machines.filter((machine) => machine.state === state).length;
    const recorded = run.waves.find((item) => item.number === wave.number);
    return {
      ...wave,
      label: `Wave ${wave.number}${wave.kind === 'Canary' ? ' (canary)' : ''}`,
      size: machines.length,
      inProgress: machines.filter((machine) => ACTIVE.includes(machine.state)).length,
      completed: count('Completed'),
      failed: count('Failed'),
      notDrained: count('NotDrained'),
      started: recorded.startedAt && Date.parse(recorded.startedAt) <= time ? formatTime(recorded.startedAt) : '',
      finished: recorded.finishedAt && Date.parse(recorded.finishedAt) <= time && wave.state !== 'Running' ? formatTime(recorded.finishedAt) : '',
    };
  });
}

const VIEWS = {
  overview: {
    title: () => 'Waves',
    rows: () => waveRows(),
    columns: [
      { label: 'Wave', key: 'label' },
      { label: 'State', render: (row) => stateCell(row.state, row.state === 'Running' ? 'Running' : STATE_LABEL[row.state] ?? row.state) },
      { label: 'Machines', key: 'size', num: true },
      { label: 'In progress', key: 'inProgress', num: true },
      { label: 'Patched', key: 'completed', num: true },
      { label: 'Failed', render: (row) => (row.failed ? `<span class="state bad">${row.failed}</span>` : '0'), num: true },
      { label: 'Not drained', key: 'notDrained', num: true },
      { label: 'Budget', key: 'failureBudget', num: true },
      { label: 'Started', key: 'started', num: true },
      { label: 'Finished', key: 'finished', num: true },
    ],
    key: 'label',
    select: (key) => { node = `wave-${key.match(/\d+/)[0]}`; selected = null; },
  },
  machines: {
    title: () => 'All machines',
    rows: () => snapshot.machines,
    columns: machineColumns,
    key: 'name',
  },
  attention: {
    title: () => 'Needs attention',
    rows: () => snapshot.machines.filter((machine) => ['Failed', 'NotDrained', 'Deferred'].includes(machine.state)),
    columns: [
      { label: 'Machine', key: 'name' },
      { label: 'State', render: (row) => stateCell(row.state) },
      { label: 'Maintenance mode', render: (row) => (row.maintenance ? 'On' : '<span class="muted">Off</span>') },
      { label: 'Why', key: 'detail', wrap: true },
    ],
    key: 'name',
    empty: 'Nothing needs attention at this point of the change.',
  },
  excluded: {
    title: () => 'Left out before the change',
    rows: () => run.exclusions,
    columns: [
      { label: 'Machine', key: 'name' },
      { label: 'Delivery group', key: 'deliveryGroup' },
      { label: 'Reason', key: 'reason', wrap: true },
    ],
    key: 'name',
    empty: 'No machine was left out.',
  },
  timeline: {
    title: () => 'Timeline',
    rows: () => run.events.filter((event) => Date.parse(event.time) <= time).map((event, index) => ({ ...event, index: String(index) })).reverse(),
    columns: [
      { label: 'Time', render: (row) => formatTime(row.time), num: true },
      { label: 'Wave', render: (row) => (row.wave ? e(row.wave) : ''), num: true },
      { label: 'Machine', key: 'machine' },
      { label: 'Step', render: (row) => e(STEP_LABEL[row.step] ?? row.step) },
      { label: 'Detail', key: 'detail', wrap: true },
    ],
    key: 'index',
  },
};

function currentView() {
  if (node.startsWith('wave-')) {
    const number = Number(node.slice(5));
    const wave = snapshot.waves.find((item) => item.number === number);
    return {
      title: () => `Wave ${number}${wave.kind === 'Canary' ? ' (canary)' : ''}`,
      rows: () => snapshot.machines.filter((machine) => machine.wave === number),
      columns: machineColumns,
      key: 'name',
    };
  }
  return VIEWS[node];
}

function renderTree() {
  const counts = countsAt(snapshot);
  const attention = counts.Failed + counts.NotDrained + counts.Deferred;
  const link = (id, label, extra = '', dot = '') => `<li><a href="#${id}" data-node="${id}"${node === id ? ' aria-current="page"' : ''}>${dot}<span>${e(label)}</span>${extra}</a></li>`;
  $('#tree').innerHTML = [
    '<li class="group">Change</li>',
    link('overview', 'Waves', `<span class="count">${snapshot.waves.length}</span>`),
    ...snapshot.waves.map((wave) => link(`wave-${wave.number}`, `Wave ${wave.number}${wave.kind === 'Canary' ? ' (canary)' : ''}`, `<span class="count">${wave.machines.length}</span>`, `<span class="dot ${wave.state}" title="${e(wave.state)}"></span>`)),
    '<li class="group">Machines</li>',
    link('machines', 'All machines', `<span class="count">${snapshot.machines.length}</span>`),
    link('attention', 'Needs attention', attention ? `<span class="alert">${attention}</span>` : '<span class="count">0</span>'),
    link('excluded', 'Left out', `<span class="count">${run.exclusions.length}</span>`),
    '<li class="group">Record</li>',
    link('timeline', 'Timeline'),
  ].join('');
  for (const anchor of document.querySelectorAll('[data-node]')) {
    anchor.addEventListener('click', (event) => {
      event.preventDefault();
      node = anchor.dataset.node;
      selected = null;
      $('#list-filter').value = '';
      render();
    });
  }
}

function renderList() {
  const view = currentView();
  const filter = $('#list-filter').value.trim().toLowerCase();
  let rows = view.rows();
  const total = rows.length;
  if (filter) rows = rows.filter((row) => JSON.stringify(row).toLowerCase().includes(filter));
  $('#list-title').textContent = view.title();
  $('#list-count').textContent = filter ? `${rows.length} of ${total}` : `${total}`;
  const onSelect = (key) => {
    if (view.select) view.select(key);
    else selected = key;
    render();
  };
  const container = $('#list');
  const scroll = container.scrollTop;
  container.innerHTML = grid(view.columns, rows, { key: view.key, onSelect, empty: view.empty });
  container.scrollTop = scroll;
  bindRows(container, onSelect);
}

function renderDetails() {
  const title = $('#details-title');
  const body = $('#details');
  const machine = selected && snapshot.machines.find((item) => item.name === selected);
  const excluded = node === 'excluded' && selected && run.exclusions.find((item) => item.name === selected);
  const event = node === 'timeline' && selected && run.events[Number(selected)];

  if (machine) {
    const recorded = run.machines.find((item) => item.name === machine.name);
    const steps = machineEvents(run, machine.name).filter((item) => Date.parse(item.time) <= time);
    const patched = recorded.patchFinishedAt && Date.parse(recorded.patchFinishedAt) <= time;
    title.innerHTML = `${e(machine.name)}<small>${e(machine.deliveryGroup)}</small>`;
    body.innerHTML = [
      machine.detail ? `<p class="callout ${machine.state === 'Failed' ? 'bad' : ''}">${e(machine.detail)}</p>` : '',
      props([
        ['State', stateCell(machine.state)],
        ['Wave', e(machine.wave)],
        ['Maintenance mode', machine.maintenance ? 'On' : 'Off'],
        ['Registration', e(machine.registration)],
        ['Sessions at drain', recorded.sessionsAtDrain == null || !steps.length ? '-' : e(recorded.sessionsAtDrain)],
        ['Users messaged', recorded.messageSent && steps.some((item) => item.step === 'MessageSent') ? 'Yes' : 'No'],
      ]),
      '<h3 class="section-title">Steps</h3>',
      `<div class="grid-wrap">${grid([
        { label: 'Time', render: (row) => formatTime(row.time), num: true },
        { label: 'Step', render: (row) => e(STEP_LABEL[row.step] ?? row.step) },
        { label: 'Detail', key: 'detail', wrap: true },
      ], steps, { empty: 'Nothing has happened to this machine yet.' })}</div>`,
      patched && recorded.installed.length
        ? `<h3 class="section-title">Installed</h3><ul class="list-plain">${recorded.installed.map((item) => `<li>${e(item)}</li>`).join('')}</ul>`
        : '',
    ].join('');
    return;
  }
  if (excluded) {
    title.innerHTML = `${e(excluded.name)}<small>${e(excluded.deliveryGroup)}</small>`;
    body.innerHTML = props([
      ['Reason', e(excluded.reason)],
      ['Catalog', e(excluded.catalog)],
      ['Provisioning', `${e(excluded.provisioning)}, ${e(excluded.allocation)}`],
      ['Sessions at plan', e(excluded.sessionsAtPlan)],
    ]);
    return;
  }
  if (event) {
    title.textContent = STEP_LABEL[event.step] ?? event.step;
    body.innerHTML = props([
      ['Time', `${formatTime(event.time)} UTC`],
      ['Wave', e(event.wave || '-')],
      ['Machine', e(event.machine || '-')],
      ['Detail', e(event.detail || '-')],
    ]);
    return;
  }

  // Nothing selected: the change itself.
  const m = run.maintenance;
  title.innerHTML = `${e(m.name)}${m.change ? `<small>${e(m.change)}</small>` : ''}`;
  body.innerHTML = props([
    ['Window', `${formatTime(m.windowStart)} to ${formatTime(m.windowEnd)} UTC (${e(m.windowStart.slice(0, 10))})`],
    ['Delivery groups', e(m.deliveryGroups.join(', '))],
    ['Waves', `Canary of ${e(m.canarySize)} with no failure allowed, then waves of ${e(m.waveSize)} with a budget of ${e(m.failureBudget)}`],
    ['Patched at a time', e(m.concurrency)],
    ['Drain', `Up to ${e(m.drainTimeoutMinutes)} minutes, then ${m.forceLogoff ? 'sessions are logged off' : 'the machine goes back into service unpatched'}`],
    ['User message', m.message ? e(`${m.message.title}: ${m.message.text}`) : 'None'],
    ['Windows updates', e(m.windowsUpdates.length ? m.windowsUpdates.join(', ') : 'Not installed')],
    ['Applications', e(m.software.map((item) => item.name).join(', ') || 'None')],
    ['After the restart', `Registered within ${e(m.rebootTimeoutMinutes)} minutes; ${e(m.services.join(', '))} running; no requested update left`],
    ['Provider', run.simulation ? 'Simulation: no real machine was changed' : e(run.provider)],
  ]) + '<p class="callout">Select a wave or a machine to see its details. Use Replay to watch the change from the start of the window.</p>';
}

function renderClock() {
  $('#clock').value = String(time);
  $('#clock-label').textContent = `${formatTime(time)} UTC`;
  const [text, tone] = outcomeText();
  const outcome = $('#outcome');
  outcome.textContent = snapshot.finished ? text : '';
  outcome.className = `outcome ${snapshot.finished ? tone : ''}`;
  const counts = countsAt(snapshot);
  $('#status-left').textContent = [
    `${counts.total} planned`,
    `${counts.active} in progress`,
    `${counts.Completed} patched`,
    `${counts.Failed} failed`,
    `${counts.NotDrained} not drained`,
    counts.Deferred ? `${counts.Deferred} deferred` : '',
    counts.NotStarted ? `${counts.NotStarted} not started` : '',
    `${counts.inMaintenance} in maintenance mode`,
    run.simulation ? 'Simulation' : run.provider,
  ].filter(Boolean).join(' · ');
}

function render() {
  snapshot = stateAt(run, time);
  renderClock();
  renderTree();
  renderList();
  renderDetails();
}

// ------------------------------------------------------------------ playback

function stop() {
  clearInterval(timer);
  timer = null;
  $('#play').textContent = 'Replay';
}

function play() {
  if (timer) {
    stop();
    return;
  }
  if (time >= bounds.end) time = bounds.start;
  $('#play').textContent = 'Pause';
  timer = setInterval(() => {
    time = Math.min(bounds.end, time + Number($('#speed').value) * 100);
    if (time >= bounds.end) stop();
    render();
  }, 100);
}

function showRun(value) {
  stop();
  run = validateRun(value);
  bounds = timeBounds(run);
  time = bounds.end;
  node = 'overview';
  selected = null;
  $('#clock').min = String(bounds.start);
  $('#clock').max = String(bounds.end);
  const m = run.maintenance;
  $('#change-line').textContent = `${m.change ? `${m.change} · ` : ''}${m.name}`;
  $('#notice').hidden = true;
  render();
}

function notice(message) {
  $('#notice').textContent = message;
  $('#notice').hidden = false;
}

async function loadScenario(id) {
  const scenario = scenarios.find((item) => item.id === id) ?? scenarios[0];
  const response = await fetch(scenario.file);
  if (!response.ok) throw new Error(`${scenario.file}: HTTP ${response.status}`);
  showRun(await response.json());
  $('#scenario').value = scenario.id;
  $('#scenario').title = scenario.description;
}

async function start() {
  $('#play').addEventListener('click', play);
  $('#clock').addEventListener('input', () => {
    stop();
    time = Number($('#clock').value);
    render();
  });
  $('#list-filter').addEventListener('input', renderList);
  $('#scenario').addEventListener('change', () => loadScenario($('#scenario').value).catch((error) => notice(error.message)));
  $('#open-file').addEventListener('change', async (event) => {
    const [file] = event.target.files;
    event.target.value = '';
    if (!file) return;
    try {
      showRun(JSON.parse(await file.text()));
      $('#scenario').value = '';
    } catch (error) {
      notice(`Could not open ${file.name}: ${error.message}`);
    }
  });

  const response = await fetch('data/index.json');
  if (!response.ok) throw new Error(`data/index.json: HTTP ${response.status}`);
  scenarios = await response.json();
  $('#scenario').innerHTML = scenarios.map((item) => `<option value="${e(item.id)}">${e(item.title)}</option>`).join('')
    + '<option value="" disabled hidden>Your run.json</option>';
  await loadScenario(new URLSearchParams(location.search).get('scenario') ?? scenarios[0].id);
}

start().catch((error) => notice(`Could not load the demo runs: ${error.message}`));
