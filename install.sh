#!/bin/bash
# Build and install Agent Launcher, the AI Service Switcher, Reply Clock and UsageBar.
#   ./install.sh [--login]     --login also starts Reply Clock and UsageBar when you log in
# Run it again to update. README.md says what it puts where; ./uninstall.sh takes it out.
set -euo pipefail
cd "$(dirname "$0")"

LOGIN=""
[[ "${1:-}" == "--login" ]] && LOGIN="--login"
PYTHON="${PYTHON:-python3}"

if ! command -v swiftc >/dev/null || ! command -v "$PYTHON" >/dev/null; then
  echo "Swift or Python 3 is missing. Install Apple's command line tools first: xcode-select --install"
  exit 1
fi

echo "== Reply Clock (the overlay and its hooks)"
ReplyClock/build.sh $LOGIN
"$PYTHON" ReplyClock/install_hooks.py

echo "== UsageBar (the menu bar meters)"
UsageBar/build.sh $LOGIN

echo "== AI Service Switcher (the VS Code extension)"
"$PYTHON" build_service_switcher.py
"$PYTHON" install_service_switcher.py

echo "== Agent Launcher"
"$PYTHON" build_agent_launcher.py
"$PYTHON" install_agent_launcher.py --no-open

open "$HOME/Applications/ReplyClock.app"
open "$HOME/Applications/UsageBar.app"

cat <<'EOF'

Installed. What is left for you:
  1. Allow Reply Clock under System Settings > Privacy & Security > Accessibility.
     (After an update: remove its old entry there and add it again.)
  2. Codex only: trust the new hooks (/hooks in the Codex CLI, or Settings > Hooks).
  3. Reload VS Code windows that are already open (Developer: Reload Window).
  4. Open Agent Launcher from the Desktop.
EOF
