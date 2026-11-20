#!/usr/bin/env python3
"""Open VS Code agent workspaces once in a chosen display grid.

QUICK START (on your Mac, Python 3.9+):
    python3 six_agents.py setup /absolute/path/to/project

Run the printed manual command, or use the Agent Launcher app, which is built on this module.
Opening a workspace does not start scripts or rearrange other windows.

macOS permissions: allow Accessibility for the program running this script
(Agent Launcher, or Terminal for a manual run), and allow that program to
control System Events under Automation if prompted.
Managed windows automatically leave macOS full-screen mode before tiling.

By default, tries to open the installed Codex sidebar, resolving its command
name from the local extension manifest. No prompts or agent jobs are sent.
    python3 six_agents.py setup /path/to/project --chat none
    python3 six_agents.py setup /path/to/project --chat-command 'Chat: Open Chat'
--chat-command must be the exact visible Command Palette label on your Mac.
Optional chat opening uses keyboard automation; leave it off if you prefer to
restore your existing panels/chats. Use the mouse/keyboard after tiling ends.

Separate project folders / existing Git worktrees, in row-major order:
    python3 six_agents.py setup /path/agent1 /path/agent2 /path/agent3 \
        /path/agent4 /path/agent5 /path/agent6
One folder is shared by all six windows; use separate worktrees when agents
should edit independently. This script never creates branches or worktrees.

Setup prints paths to its generated workspaces and config. To open or re-tile:
    python3 /printed/path/six_agents.py arrange /printed/path/config.json
Setup stores everything in ~/Library/Application Support/SixAgents/<id> and
does not edit project files or VS Code user settings.
Deleting that directory removes the setup. Close its windows manually first.

The one-time launcher calculates final tile positions directly. App minimum
window sizes or insufficient logical resolution can prevent an exact
3-by-2 landscape or 2-by-3 portrait fit. The script reports mismatches.
This script must run locally on macOS, not inside a remote/SSH/container host.
"""

import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


ACTIONS = (
    "top-left-sixth", "top-center-sixth", "top-right-sixth",
    "bottom-left-sixth", "bottom-center-sixth", "bottom-right-sixth",
)

# JXA accesses AppKit display geometry and macOS Accessibility through the
# system's built-in osascript; no pip packages or hardcoded screen pixels.
JXA = r'''
ObjC.import('AppKit');
function run(argv) {
    var operation = argv[0], cfg = JSON.parse(argv[1]);
    if (operation === 'screens') {
        var ss = $.NSScreen.screens, result = [];
        var primaryTop = ss.objectAtIndex(0).frame.size.height;
        for (var i = 0; i < ss.count; i++) {
            var s = ss.objectAtIndex(i), f = s.frame, v = s.visibleFrame;
            // Inactive external displays can report a visibleFrame that still
            // includes the menu bar. Reserve it before calculating final tiles.
            var top = primaryTop - f.origin.y - f.size.height;
            var visibleTop = Math.max(primaryTop - v.origin.y - v.size.height,
                                      top + Math.max(25, Number(s.safeAreaInsets.top)));
            result.push({
                id: Number(ObjC.unwrap(s.deviceDescription.objectForKey('NSScreenNumber'))),
                name: ObjC.unwrap(s.localizedName),
                frame: {x: f.origin.x, y: primaryTop - f.origin.y - f.size.height,
                        width: f.size.width, height: f.size.height},
                visible: {x: v.origin.x, y: visibleTop,
                          width: v.size.width, height: primaryTop - v.origin.y - visibleTop}
            });
        }
        return JSON.stringify(result);
    }
    var se = Application('System Events');
    var ps = se.applicationProcesses.whose({bundleIdentifier: cfg.bundle_id})();
    if (!ps.length) return '[]';
    var windows = [];
    ps.forEach(function(p) {
        p.windows().forEach(function(w) { windows.push({process: p, window: w}); });
    });
    function snapshot(w) {
        var fullscreen = false;
        try { fullscreen = Boolean(w.attributes.byName('AXFullScreen').value()); } catch(e) {}
        return {title: w.name(), position: w.position(), size: w.size(), fullscreen: fullscreen};
    }
    if (operation === 'windows') {
        return JSON.stringify(windows.map(function(item) { return snapshot(item.window); }));
    }
    if (operation === 'tile') {
        // One deterministic pass over the requested windows. There is no
        // ongoing layout watcher.
        var result = [];
        cfg.placements.forEach(function(item) {
            var matches = windows.filter(function(candidate) {
                return candidate.window.name().indexOf(item.marker) >= 0;
            });
            if (matches.length !== 1) throw new Error('Expected one window for ' + item.marker);
            var p = matches[0].process, title = matches[0].window.name();
            var w = p.windows.byName(title), r = item.rect;
            if (snapshot(w).fullscreen) throw new Error('Window is still in full-screen mode: ' + item.marker);
            if (w.attributes.byName('AXMinimized').value()) w.attributes.byName('AXMinimized').value = false;
            // A tall portrait tile may initially exceed the source display.
            // Size before and after moving; both sizes are the final target.
            w.size = [r.width, r.height];
            w.position = [r.x, r.y];
            w.size = [r.width, r.height];
            result.push({marker: item.marker, target: r});
        });
        return JSON.stringify(result);
    }
    if (operation === 'chats') {
        cfg.markers.forEach(function(marker) {
            var matches = windows.filter(function(item) { return item.window.name().indexOf(marker) >= 0; });
            if (matches.length !== 1) throw new Error('Expected one window for ' + marker);
            var p = matches[0].process;
            var w = p.windows.byName(matches[0].window.name());
            p.frontmost = true;
            w.actions.byName('AXRaise').perform();
            delay(0.1);
            // A scoped VS Code runCommands binding: open the existing Codex
            // chat, maximize its side bar, and hide the bottom panel.
            se.keyCode(25, {using: ['command down', 'option down', 'shift down']});
            delay(0.25);
        });
        return JSON.stringify({count: cfg.markers.length});
    }
    var targets = windows.filter(function(item) { return item.window.name().indexOf(cfg.marker) >= 0; });
    if (targets.length !== 1) throw new Error('Expected one window for ' + cfg.marker
        + '; found ' + targets.length);
    var p = targets[0].process;
    // AX window indices change when a full-screen Space opens or closes.
    // Keep a title-based reference rather than retaining the enumerated index.
    var title = targets[0].window.name(), w = p.windows.byName(title);
    function step(label, fn) {
        try { return fn(); }
        catch(e) { throw new Error(label + ': ' + String(e)); }
    }
    step('restore minimized window', function() {
        if (w.attributes.byName('AXMinimized').value())
            w.attributes.byName('AXMinimized').value = false;
    });
    step('activate VS Code', function() { p.frontmost = true; });
    step('raise window', function() { w.actions.byName('AXRaise').perform(); });
    if (operation === 'normalize') {
        if (snapshot(w).fullscreen) {
            step('exit full-screen', function() { w.attributes.byName('AXFullScreen').value = false; });
            // Do not read this AX reference during the Space animation.
            // Python waits and obtains fresh references in a new osascript call.
            return JSON.stringify({transition: true});
        }
        return JSON.stringify({transition: false});
    }
    if (operation === 'place') {
        var r = cfg.rect;
        // Shrink before moving so the window fits wholly on the target display.
        // Position twice: macOS can constrain the first move during resizing.
        w.size = [Math.round(r.width), Math.round(r.height)];
        delay(0.15);
        w.position = [Math.round(r.x), Math.round(r.y)];
        delay(0.2);
        w.size = [Math.round(r.width), Math.round(r.height)];
        w.position = [Math.round(r.x), Math.round(r.y)];
        delay(0.2);
    } else if (operation === 'chat') {
        se.keystroke('p', {using: ['command down', 'shift down']});
        delay(0.45);
        se.keystroke(cfg.label);
        delay(0.7);
        se.keyCode(36);
        delay(0.45);
    }
    if (operation === 'focus') {
        delay(0.2);
        if (!p.frontmost() || p.windows[0].name().indexOf(cfg.marker) < 0)
            throw new Error('Could not focus ' + cfg.marker + '. Leave the keyboard and mouse idle during tiling.');
    }
    return JSON.stringify(snapshot(w));
}
'''


def run(argv, **kwargs):
    result = subprocess.run(argv, text=True, capture_output=True, **kwargs)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"{Path(str(argv[0])).name} failed: {detail}")
    return result.stdout.strip()


def mac(operation, **payload):
    try:
        output = run(
            ["/usr/bin/osascript", "-l", "JavaScript", "-", operation,
             json.dumps(payload)], input=JXA, timeout=25,
        )
    except RuntimeError as exc:
        raise RuntimeError(f"macOS {operation} ({payload.get('marker', '')}): {exc}") from exc
    return json.loads(output)


def vscode_app(bundle_id):
    standard = [Path("/Applications/Visual Studio Code.app"),
                Path.home() / "Applications/Visual Studio Code.app"]
    if bundle_id == "com.microsoft.VSCodeInsiders":
        standard = [p.with_name("Visual Studio Code - Insiders.app") for p in standard]
    # Check the bundle ID as well, to avoid mixing stable and Insiders windows.
    import plistlib
    for app in standard:
        plist = app / "Contents/Info.plist"
        if plist.is_file():
            with plist.open("rb") as stream:
                if plistlib.load(stream).get("CFBundleIdentifier") == bundle_id:
                    return app
    try:
        path = run(["/usr/bin/osascript", "-e",
                    f'POSIX path of (path to application id "{bundle_id}")'], timeout=20)
        return Path(path)
    except RuntimeError as exc:
        raise RuntimeError("Cannot find VS Code. Install it in /Applications.") from exc


def code_cli(bundle_id):
    # Prefer the selected app's CLI over a potentially different `code` in PATH.
    app = vscode_app(bundle_id)
    for name in ("code", "code-insiders"):
        candidate = app / "Contents/Resources/app/bin" / name
        if candidate.is_file():
            return str(candidate)
    raise RuntimeError(f"Cannot find the VS Code CLI inside {app}.")


def codex_label():
    """Use the installed manifest rather than assuming an English command title."""
    candidates = []
    for directory in (".vscode", ".vscode-insiders"):
        candidates.extend((Path.home() / directory / "extensions").glob("openai.chatgpt-*/package.json"))
    for manifest in sorted(candidates, key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            pkg = json.loads(manifest.read_text())
            translations = {}
            nls = manifest.with_name("package.nls.json")
            if nls.exists():
                translations = json.loads(nls.read_text())

            def label(value):
                if isinstance(value, dict):
                    return value.get("value", value.get("original", ""))
                if value.startswith("%") and value.endswith("%"):
                    return translations.get(value[1:-1], "")
                return value

            for command in pkg.get("contributes", {}).get("commands", []):
                if command.get("command") == "chatgpt.openSidebar":
                    title = label(command.get("title", ""))
                    category = label(command.get("category", ""))
                    if title:
                        return f"{category}: {title}" if category else title
        except (ValueError, OSError, AttributeError):
            continue
    return None


def workspace_settings(project, marker, chat_only=True):
    return {
        "window.title": f"{marker} - {Path(project).name}",
        "workbench.startupEditor": "none", "editor.minimap.enabled": False,
        # Zen mode otherwise restores native full-screen mode with its default
        # settings. Agent windows should remain ordinary tiled windows.
        "zenMode.fullScreen": False, "zenMode.restore": False,
        "chatgpt.openOnStartup": chat_only,
        "workbench.secondarySideBar.defaultVisibility": "maximized" if chat_only else "hidden",
        "workbench.secondarySideBar.forceMaximized": chat_only,
        "workbench.secondarySideBar.showLabels": True,
        "claudeCode.preferredLocation": "sidebar",
        "workbench.statusBar.visible": not chat_only,
        "workbench.activityBar.location": "hidden" if chat_only else "default",
        "workbench.layoutControl.enabled": not chat_only,
    }


def setup(args):
    folders = [str(Path(p).expanduser().resolve()) for p in args.folders]
    if len(folders) == 1:
        folders *= 6
    if len(folders) != 6:
        raise ValueError("Supply either one shared project folder or six separate folders.")
    for folder in folders:
        if not Path(folder).is_dir():
            raise ValueError(f"Project folder does not exist: {folder}")
    identity = hashlib.sha256(json.dumps(folders).encode()).hexdigest()[:10]
    root = Path.home() / "Library/Application Support/SixAgents" / identity
    root.mkdir(parents=True, exist_ok=True)
    launcher = root / "six_agents.py"
    if Path(__file__).resolve() != launcher.resolve():
        shutil.copy2(__file__, launcher)
    config_file = root / "config.json"
    entries = []
    for index, folder in enumerate(folders, 1):
        marker = f"Agent {index} [{identity}]"
        filename = "Six-Agents.code-workspace" if index == 1 else f"Agent-{index}.code-workspace"
        workspace_file = root / filename
        workspace = {
            "folders": [{"path": folder}],
            "settings": workspace_settings(folder, marker, args.chat == "codex"),
        }
        if index == 1:
            workspace["tasks"] = {
                "version": "2.0.0", "tasks": [{
                    "label": "Open and tile six agent windows",
                    "type": "process", "command": sys.executable,
                    "args": [str(launcher), "arrange", str(config_file)],
                    "options": {"cwd": folder},
                    "runOptions": {"instanceLimit": 1},
                    "presentation": {"reveal": "silent", "panel": "dedicated", "focus": False},
                    "problemMatcher": [],
                }],
            }
        workspace_file.write_text(json.dumps(workspace, indent=2) + "\n")
        entries.append({"workspace": str(workspace_file), "marker": marker})
    config = {
        "bundle_id": "com.microsoft.VSCodeInsiders" if args.insiders else "com.microsoft.VSCode",
        "chat": args.chat, "chat_command": args.chat_command,
        "timeout": args.timeout, "settle": args.settle,
        "one_shot": True, "chat_only": args.chat == "codex",
        "windows": entries,
    }
    config_file.write_text(json.dumps(config, indent=2) + "\n")
    print("Open this workspace in VS Code:")
    print(entries[0]["workspace"])
    print("\nOpening a workspace starts no scripts. Use the manual command or the Desktop app.")
    print("Manual re-tile command:")
    import shlex
    print(shlex.join([sys.executable, str(launcher), "arrange", str(config_file)]))
    return entries[0]["workspace"]


def choose_screen(screens):
    if not screens:
        raise RuntimeError("No connected screens found.")
    # Physical ordering follows macOS System Settings > Displays > Arrange.
    return min(screens, key=lambda s: (s["frame"]["x"], s["frame"]["y"]))


def grid_dimensions(rect, count):
    if not 1 <= count <= 24:
        raise ValueError("Choose between 1 and 24 windows per display.")
    portrait = rect["height"] > rect["width"]
    if count == 1:
        return 1, 1
    if count in (2, 3):
        return (1, count) if portrait else (count, 1)
    if count == 4:
        return 2, 2
    if count in (5, 6):
        return (2, 3) if portrait else (3, 2)
    def score(columns):
        rows = math.ceil(count / columns)
        aspect = rect["width"] / columns / (rect["height"] / rows)
        return abs(math.log(aspect / 1.3)) + 0.7 * (columns * rows - count)
    columns = min(range(1, count + 1), key=score)
    return columns, math.ceil(count / columns)


def layout_cells(rect, count=6):
    """Yield (name, cell) for each window, in reading order.

    Sixths become two columns and three rows in portrait: the corner cells keep
    their corners, the two center cells become middle-left and middle-right.
    """
    portrait = rect["height"] > rect["width"]
    columns, rows = grid_dimensions(rect, count)
    for index in range(count):
        row, column = divmod(index, columns)
        action = None
        if count == 1:
            action = "maximize"
        elif count == 2:
            action = (("top-half", "bottom-half") if portrait else ("left-half", "right-half"))[index]
        elif count == 3:
            action = ("first-third", "center-third", "last-third")[index]
        elif count == 4:
            action = ("top-left", "top-right", "bottom-left", "bottom-right")[index]
        elif count in (5, 6):
            action = ACTIONS[(0, 2, 1, 4, 3, 5)[index] if portrait else index]
        left = round(rect["x"] + column * rect["width"] / columns)
        top = round(rect["y"] + row * rect["height"] / rows)
        right = round(rect["x"] + (column + 1) * rect["width"] / columns)
        bottom = round(rect["y"] + (row + 1) * rect["height"] / rows)
        yield action, {"x": left, "y": top,
                                      "width": right - left, "height": bottom - top}


def plan_layout(cfg, screens):
    displays = cfg.get("displays")
    if displays is None:
        displays = [{"id": choose_screen(screens).get("id"), "count": 6}]
    assignments = []
    used = set()
    for display in displays:
        screen_id = str(display["id"])
        if screen_id in used:
            raise ValueError("A display was selected twice.")
        used.add(screen_id)
        matches = [s for s in screens if str(s.get("id")) == screen_id]
        if len(matches) != 1:
            raise ValueError("A selected display was disconnected. Refresh the displays and try again.")
        screen = matches[0]
        assignments.extend((screen, action, cell)
                           for action, cell in layout_cells(screen["visible"], display["count"]))
    if len(assignments) != len(cfg["windows"]):
        raise ValueError("The display allocation must match the number of agent windows.")
    return assignments


def fits_cell(window, cell):
    x, y = window["position"]
    width, height = window["size"]
    # Allow small gaps and integer rounding, but reject overlap,
    # full-screen windows, the wrong display, or a different sixth.
    return (not window.get("fullscreen", False)
            and abs(width - cell["width"]) <= max(32, cell["width"] * 0.12)
            and abs(height - cell["height"]) <= max(32, cell["height"] * 0.12)
            and abs(x + width / 2 - cell["x"] - cell["width"] / 2) <= 32
            and abs(y + height / 2 - cell["y"] - cell["height"] / 2) <= 32)


def on_screen(window, rect):
    x, y = window["position"]
    width, height = window["size"]
    return (x >= rect["x"] - 4 and y >= rect["y"] - 4
            and x + width <= rect["x"] + rect["width"] + 4
            and y + height <= rect["y"] + rect["height"] + 4)


def wait_for_window(bundle_id, marker, timeout):
    deadline = time.monotonic() + timeout
    while True:
        matches = [w for w in mac("windows", bundle_id=bundle_id) if marker in w["title"]]
        if len(matches) == 1:
            return matches[0]
        if time.monotonic() >= deadline:
            if len(matches) > 1:
                raise RuntimeError(f"Multiple windows match {marker}. Close the duplicate and retry.")
            raise RuntimeError(f"Timed out waiting for {marker}. Dismiss any workspace trust or startup dialogs and retry.")
        time.sleep(0.5)


def normalize_window(bundle_id, marker):
    result = mac("normalize", bundle_id=bundle_id, marker=marker)
    if result["transition"]:
        time.sleep(2)
        deadline = time.monotonic() + 15
        while True:
            window = wait_for_window(bundle_id, marker, 5)
            if not window.get("fullscreen"):
                return
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Could not leave full-screen mode: {marker}")
            time.sleep(0.5)


def wait_for_windows(bundle_id, markers, timeout):
    """One bounded readiness wait for the entire batch; no watcher survives it."""
    deadline = time.monotonic() + timeout
    while True:
        windows = mac("windows", bundle_id=bundle_id)
        grouped = {m: [w for w in windows if m in w["title"]] for m in markers}
        fullscreen = [m for m, matches in grouped.items()
                      if len(matches) == 1 and matches[0].get("fullscreen")]
        if fullscreen:
            # Recovery for old windows saved in native full-screen Spaces.
            for marker in fullscreen:
                normalize_window(bundle_id, marker)
        elif all(len(matches) == 1 for matches in grouped.values()):
            return {m: matches[0] for m, matches in grouped.items()}
        if time.monotonic() >= deadline:
            pending = [m for m, matches in grouped.items() if len(matches) != 1]
            raise RuntimeError("Timed out opening the agent windows: " + ", ".join(pending)
                               + ". Dismiss any workspace trust dialogs and try again.")
        time.sleep(0.25)


def arrange_once(cfg):
    bundle_id = cfg["bundle_id"]
    plan_layout(cfg, mac("screens"))  # Fail before opening anything if a screen disappeared.
    markers = [w["marker"] for w in cfg["windows"]]
    if not markers:
        raise ValueError("Choose at least one agent window.")
    print(f"Opening {len(markers)} windows, then placing each in its final tile.", flush=True)
    for _ in range(len(markers)):
        windows = mac("windows", bundle_id=bundle_id)
        fullscreen = [m for m in markers if any(m in w["title"] and w.get("fullscreen") for w in windows)]
        if not fullscreen:
            break
        for marker in fullscreen:
            normalize_window(bundle_id, marker)
    existing = {m for m in markers if any(m in w["title"] for w in windows)}
    missing = [w["workspace"] for w in cfg["windows"] if w["marker"] not in existing]
    if missing:
        env = os.environ.copy()
        for key in ("ELECTRON_RUN_AS_NODE", "VSCODE_IPC_HOOK_CLI"):
            env.pop(key, None)
        # VS Code accepts multiple .code-workspace files in one invocation and
        # opens them as separate windows, attached to their project folders.
        run([code_cli(bundle_id), "--new-window", *missing], env=env, timeout=30)
    wait_for_windows(bundle_id, markers, cfg.get("timeout", 90))
    assignments = plan_layout(cfg, mac("screens"))
    placements = [{"marker": entry["marker"], "rect": cell}
                  for entry, (_, _, cell) in zip(cfg["windows"], assignments)]
    mac("tile", bundle_id=bundle_id, placements=placements)
    if cfg.get("chat_shortcut") and cfg.get("chat_only"):
        mac("chats", bundle_id=bundle_id, markers=markers)
    elif cfg.get("chat") == "codex":
        label = cfg.get("chat_command") or codex_label()
        if label:
            for marker in markers:
                mac("chat", bundle_id=bundle_id, marker=marker, label=label)
    time.sleep(cfg.get("settle", 0.25))
    # One final snapshot, then return. No repeated resizing or background checks.
    windows = mac("windows", bundle_id=bundle_id)
    failures = []
    for entry, (screen, _, cell) in zip(cfg["windows"], assignments):
        matches = [w for w in windows if entry["marker"] in w["title"]]
        if len(matches) != 1 or not fits_cell(matches[0], cell) or not on_screen(matches[0], screen["visible"]):
            failures.append(entry["marker"])
        elif matches:
            print(f"{entry['marker']}: {screen['name']}, {matches[0]['position']}, {matches[0]['size']}", flush=True)
    if failures:
        raise RuntimeError("These windows could not fit their requested tiles: " + ", ".join(failures)
                           + ". Reduce the window count or choose a larger display.")
    print("Finished. The launcher will now exit; no layout monitor remains running.", flush=True)


def arrange(config_file):
    cfg = json.loads(config_file.read_text())
    # Prevent overlap with another launch of the same layout.
    with config_file.with_suffix(".lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("This layout is already being opened.")
            return
        return arrange_once(cfg)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="mode", required=True)
    setup_parser = commands.add_parser("setup", help="Generate six workspaces; does not open windows.")
    setup_parser.add_argument("folders", nargs="+", help="One shared folder, or six separate folders/worktrees.")
    setup_parser.add_argument("--chat", choices=("codex", "none"), default="codex")
    setup_parser.add_argument("--chat-command", help="Exact Command Palette label, overrides --chat.")
    setup_parser.add_argument("--insiders", action="store_true")
    setup_parser.add_argument("--timeout", type=float, default=90, help="Seconds to wait per window.")
    setup_parser.add_argument("--settle", type=float, default=3, help="Seconds to wait after windows appear.")
    arrange_parser = commands.add_parser("arrange", help="Open missing windows and tile them.")
    arrange_parser.add_argument("config", type=Path)
    commands.add_parser("diagnose", help="Print connected displays and visible VS Code windows.")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("Run this script on your Mac, with a local Python 3.9+ installation.")
    try:
        if args.mode == "setup":
            if args.timeout <= 0 or args.settle < 0:
                raise ValueError("--timeout must be positive and --settle cannot be negative.")
            setup(args)
        elif args.mode == "diagnose":
            print(json.dumps({"screens": mac("screens"),
                              "windows": mac("windows", bundle_id="com.microsoft.VSCode")}, indent=2))
        else:
            arrange(args.config.expanduser().resolve())
        return 0
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        print("For Accessibility errors, enable the program running this script (Agent Launcher, or Terminal for a manual run) in System Settings > Privacy & Security > Accessibility. Also allow System Events under Automation if prompted.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
