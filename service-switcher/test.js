'use strict';
const assert = require('node:assert/strict');
const { registerSwitcher, registerWindow, SERVICES } = require('./extension');
function windowHarness(title, existing = {}) {
  const files = new Map(Object.entries(existing)), context = { subscriptions: [] };
  const vscode = { workspace: { getConfiguration: section => ({ get: key => (section === 'window' && key === 'title') ? title : undefined }) } };
  const fs = {
    mkdirSync: () => {},
    writeFileSync: (file, text) => files.set(file, text),
    unlinkSync: file => files.delete(file)
  };
  const file = registerWindow(vscode, context, { fs, path: require('node:path'), home: '/Users/me', pid: 4242 });
  return { file, files, context };
}
function harness(initial = {}, failOn) {
  const handlers = new Map(), calls = [], errors = [], state = { ...initial };
  const context = { subscriptions: [], workspaceState: {
    get: (key, fallback) => state[key] ?? fallback,
    update: async (key, value) => { state[key] = value; }
  } };
  const vscode = { commands: {
    registerCommand: (id, callback) => { handlers.set(id, callback); return { dispose() {} }; },
    getCommands: async () => SERVICES.map(s => s.open),
    executeCommand: async (id, ...args) => { calls.push([id, ...args]); if (id === failOn) throw new Error('test failure'); }
  }, window: { showErrorMessage: async message => errors.push(message), showQuickPick: async () => undefined } };
  registerSwitcher(vscode, context);
  return { vscode, context, calls, handlers, errors, state };
}
(async () => {
  for (const service of SERVICES) {
    const h = harness();
    assert.equal(await h.handlers.get(service.command)(), true);
    assert.deepEqual(h.calls.slice(0, 3).map(c => c[0]), [service.open, 'workbench.action.closePanel', 'workbench.action.maximizeAuxiliaryBar']);
    assert.equal(h.state.selectedService, service.id);
    assert.equal(h.calls.length, 4);
  }
  const a = harness({ selectedService: 'claude' }), b = harness({ selectedService: 'copilot' });
  await a.handlers.get('agentWindows.restoreService')();
  await b.handlers.get('agentWindows.restoreService')();
  assert.equal(a.calls[0][0], SERVICES[1].open);
  assert.equal(b.calls[0][0], SERVICES[2].open);
  const cancelled = harness();
  assert.equal(await cancelled.handlers.get('agentWindows.chooseService')(), false);
  assert.deepEqual(cancelled.calls, []);
  const failed = harness({ selectedService: 'codex' }, SERVICES[1].open);
  assert.equal(await failed.handlers.get('agentWindows.useClaude')(), false);
  assert.equal(failed.state.selectedService, 'codex');
  assert.equal(failed.errors.length, 1);
  const missing = harness();
  missing.vscode.commands.getCommands = async () => [];
  assert.equal(await missing.handlers.get('agentWindows.useCopilot')(), false);
  assert.deepEqual(missing.calls, []);
  const picked = harness();
  picked.vscode.window.showQuickPick = async items => { assert.equal(items.length, 3); return items[1]; };
  await picked.handlers.get('agentWindows.chooseService')();
  assert.equal(picked.state.selectedService, 'claude');
  const agent = windowHarness('Agent 3 [launcher-0123abcdef] - my-project');
  assert.equal(agent.file, '/Users/me/Library/Application Support/ReplyClock/hosts/4242.json');
  assert.deepEqual(JSON.parse(agent.files.get(agent.file)), { marker: 'Agent 3 [launcher-0123abcdef]', pid: 4242 });
  agent.context.subscriptions.forEach(s => s.dispose());
  assert.equal(agent.files.size, 0);
  const stale = '/Users/me/Library/Application Support/ReplyClock/windows/Agent-3--launcher-0123abcdef-.json';
  const restarted = windowHarness('Agent 3 [launcher-0123abcdef] - my-project', { [stale]: '{"kind":"finished"}' });
  assert.equal(restarted.files.has(stale), false);
  const plain = windowHarness('${activeEditorShort}${separator}${rootName}');
  assert.equal(plain.file, undefined);
  assert.equal(plain.files.size, 0);
  console.log('Service switcher tests passed: routing, sizing, per-window restore, cancellation, failures, picker, and Reply Clock window names.');
})().catch(error => { console.error(error); process.exitCode = 1; });
