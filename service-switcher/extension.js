'use strict';

const SERVICES = Object.freeze([
  { id: 'codex', label: 'Codex', open: 'chatgpt.openSidebar', command: 'agentWindows.useCodex' },
  { id: 'claude', label: 'Claude Code', open: 'claude-vscode.sidebar.open', command: 'agentWindows.useClaude' },
  { id: 'copilot', label: 'GitHub Copilot', open: 'workbench.action.chat.open', command: 'agentWindows.useCopilot' }
]);
const STATE_KEY = 'selectedService';

function registerSwitcher(vscode, context) {
  async function switchService(service) {
    try {
      // Provider commands reveal the existing conversation in this window.
      // Do not create a new chat or submit a prompt.
      const available = await vscode.commands.getCommands();
      if (!available.includes(service.open)) {
        throw new Error(`${service.label}'s chat command is unavailable. Enable its VS Code extension and try again.`);
      }
      await vscode.commands.executeCommand(service.open);
      await vscode.commands.executeCommand('workbench.action.closePanel');
      await vscode.commands.executeCommand('workbench.action.maximizeAuxiliaryBar');
      await context.workspaceState.update(STATE_KEY, service.id);
      await vscode.commands.executeCommand('setContext', 'agentWindows.selectedService', service.id);
      return true;
    } catch (error) {
      await vscode.window.showErrorMessage(`Could not switch AI service: ${error.message || error}`);
      return false;
    }
  }
  for (const service of SERVICES) {
    context.subscriptions.push(vscode.commands.registerCommand(service.command, () => switchService(service)));
  }
  context.subscriptions.push(vscode.commands.registerCommand('agentWindows.chooseService', async () => {
    const current = context.workspaceState.get(STATE_KEY, 'codex');
    const choice = await vscode.window.showQuickPick(SERVICES.map(service => ({
      label: service.label,
      description: service.id === current ? 'Selected in this window' : '',
      service
    })), { title: 'Switch AI service', placeHolder: 'Choose the service for this chat window', ignoreFocusOut: false });
    return choice ? switchService(choice.service) : false;
  }));
  context.subscriptions.push(vscode.commands.registerCommand('agentWindows.restoreService', () => {
    const selected = context.workspaceState.get(STATE_KEY, 'codex');
    return switchService(SERVICES.find(service => service.id === selected) || SERVICES[0]);
  }));
}

// Reply Clock: name this agent window for the hooks that run beneath it. A hook walks up
// its parent processes to this extension host and reads which window it serves.
const MARKER = /^(.*?\[(?:launcher-)?[0-9a-f]{10}\])/;

function registerWindow(vscode, context, deps) {
  const { fs, path, home, pid } = deps;
  const title = vscode.workspace.getConfiguration('window').get('title') || '';
  const match = MARKER.exec(title);
  if (!match) return undefined;
  const root = path.join(home, 'Library', 'Application Support', 'ReplyClock');
  const dir = path.join(root, 'hosts');
  const file = path.join(dir, `${pid}.json`);
  try {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(file, JSON.stringify({ marker: match[1], pid }) + '\n');
  } catch (error) {
    return undefined;
  }
  // A window that starts shows no clock until its first prompt: drop the state it had before.
  const key = match[1].replace(/[^A-Za-z0-9]/g, '-');
  try { fs.unlinkSync(path.join(root, 'windows', `${key}.json`)); } catch (error) { /* none yet */ }
  context.subscriptions.push({ dispose() { try { fs.unlinkSync(file); } catch (error) { /* already gone */ } } });
  return file;
}

function activate(context) {
  const vscode = require('vscode');
  registerSwitcher(vscode, context);
  registerWindow(vscode, context, {
    fs: require('fs'), path: require('path'), home: require('os').homedir(), pid: process.pid
  });
}
function deactivate() {}
module.exports = { activate, deactivate, registerSwitcher, registerWindow, SERVICES, MARKER };
