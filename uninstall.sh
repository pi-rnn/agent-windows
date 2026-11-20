#!/bin/bash
# Take out what install.sh put in: the apps, the hooks, the VS Code extension, Reply Clock's
# files and the login items. Your projects and chats are not touched. Left in place: the four
# key bindings in VS Code's keybindings.json (they do nothing outside agent windows) and
# ~/Library/Application Support/AgentLauncher (the workspace files of your agent windows).
set -euo pipefail
cd "$(dirname "$0")"

PYTHON="${PYTHON:-python3}"
CODE="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"

pkill -x ReplyClock 2>/dev/null || true
pkill -x UsageBar 2>/dev/null || true
for label in local.replyclock local.usagebar; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done

"$PYTHON" ReplyClock/install_hooks.py --remove

if [[ -x "$CODE" ]]; then
  # Run from a VS Code terminal, these variables would send the CLI to the wrong place.
  env -u VSCODE_IPC_HOOK_CLI -u ELECTRON_RUN_AS_NODE "$CODE" \
    --uninstall-extension agent-windows.agent-service-switcher 2>/dev/null || true
fi

if [[ -L "$HOME/Desktop/Agent Launcher.app" ]]; then rm "$HOME/Desktop/Agent Launcher.app"; fi
rm -rf "$HOME/Applications/ReplyClock.app" "$HOME/Applications/UsageBar.app" \
       "$HOME/Applications/Agent Launcher.app" "$HOME/Library/Application Support/ReplyClock"
for domain in local.replyclock local.usagebar local.agentlauncher; do
  defaults delete "$domain" 2>/dev/null || true
done

echo "Removed. Reload VS Code windows that are still open."
echo "Kept: ~/Library/Application Support/AgentLauncher, and four key bindings in VS Code that"
echo "apply only in agent windows (cmd+alt+1, 2, 3 and cmd+alt+shift+9)."
