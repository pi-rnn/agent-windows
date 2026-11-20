# Agent Launcher

Opens a grid of VS Code windows on a project, one per agent, and tiles them
across your displays.

Double-click **Agent Launcher** on the Desktop. Choose a project folder, a total
of 1–24 agent windows, and any connected displays. Selecting displays balances
the total between them. Change an individual display's count for a custom split.
The preview shows the physical display arrangement and numbered agent windows.

Click **Open agent windows** and leave the keyboard and mouse idle while the
windows move. The app exits automatically after successful setup. It remembers
the last project and allocation for the next launch. Click **Refresh** after
changing the display setup if needed.

The launcher requests all missing workspace windows in one VS Code command,
places them directly in their final tiles, and checks the result once. Five
windows occupy five equal cells of the sixths grid. Other counts use equal cells
calculated for the display shape; a final grid cell may be empty. macOS and
VS Code minimum window sizes still apply; the activity log reports any window
that cannot fit.

On first use, macOS asks for permission to control System Events. Allow it.
If needed, enable Agent Launcher under **System Settings → Privacy & Security →
Accessibility** and System Events under **Automation**. The app has a button to
open the Accessibility settings and an activity log with errors.

Each project gets persistent agent workspace files so later launches reuse its
windows. Reducing the count leaves previous windows open. All agent windows use
the selected project folder. Each window is titled `Agent N [launcher-<id>]`,
the id standing for the project folder; the AI Service Switcher and Reply Clock
recognize agent windows by that title.

**Show only Codex chat** expands the chat side bar and hides the editor,
activity bar, status bar and bottom panel within each tiled window. It
preserves conversations and starts no agent jobs. A new window opens on Codex;
if you use another service, pick it once per window with **⌘⌥M** (the AI
Service Switcher), and the launcher restores that choice from then on.

No watcher, recurring task, or login item is installed. Opening a generated
workspace does not run setup: only the app starts a layout.

The app is installed in `~/Applications/Agent Launcher.app`, with a Desktop
shortcut. Its preferences use the `local.agentlauncher` defaults domain.
Generated workspaces are in `~/Library/Application Support/AgentLauncher`.

## Build and install

`install.sh` in the folder above does this. By hand, from that folder:

```bash
python3 build_agent_launcher.py      # builds dist/Agent Launcher.app
python3 install_agent_launcher.py    # copies it to ~/Applications, adds the key bindings
```

The build uses the Mac's Swift compiler and your Python 3 (standard library
only); it downloads nothing. The installer adds four key bindings to VS Code
that apply only in agent windows (⌘⌥1–3 for the services, and one the launcher
presses itself to restore each window's service), backing `keybindings.json`
up first.

`python3 -m unittest` in the folder above runs the layout tests.
`python3 six_agents.py diagnose` prints the displays and VS Code windows as the
launcher sees them.
