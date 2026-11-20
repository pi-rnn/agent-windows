"""Local backend for Agent Launcher.app; workspace identities survive layout changes."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
import six_agents


def make_config(request, screens, storage):
    project = Path(request["project"]).expanduser().resolve()
    if not project.is_dir():
        raise ValueError("Choose an existing project folder.")
    allocations = request.get("allocations", [])
    if not allocations:
        raise ValueError("Select at least one display.")
    for allocation in allocations:
        count = allocation.get("count")
        if type(count) is not int or not 1 <= count <= 24:
            raise ValueError("Each selected display needs between 1 and 24 windows.")
    total = sum(a["count"] for a in allocations)
    if total > 24:
        raise ValueError("Choose up to 24 agent windows in total.")
    identity = hashlib.sha256(str(project).encode()).hexdigest()[:10]
    root = storage / "Projects" / identity
    cfg = {
        "bundle_id": "com.microsoft.VSCode",
        "chat": "codex" if request.get("open_chat", True) else "none",
        "chat_command": None, "chat_only": request.get("open_chat", True),
        "one_shot": True, "chat_shortcut": True, "timeout": 90, "settle": 0.25,
        "displays": [{"id": a["screen_id"], "count": a["count"]} for a in allocations],
        "windows": [{"workspace": str(root / f"Agent-{i}.code-workspace"),
                     "marker": f"Agent {i} [launcher-{identity}]"}
                    for i in range(1, total + 1)],
    }
    # Validate display presence and counts before writing or opening anything.
    six_agents.plan_layout(cfg, screens)
    return project, cfg


def write_workspaces(project, cfg):
    for entry in cfg["windows"]:
        workspace = Path(entry["workspace"])
        workspace.parent.mkdir(parents=True, exist_ok=True)
        content = json.loads(workspace.read_text()) if workspace.exists() else {"folders": [{"path": str(project)}]}
        settings = content.setdefault("settings", {})
        settings.update(six_agents.workspace_settings(project, entry["marker"], cfg.get("chat_only", False)))
        # Workspace opening must never start the layout. Only the Desktop app
        # or an explicitly invoked manual command starts it.
        for task in content.get("tasks", {}).get("tasks", []):
            if task.get("label") == "Open and tile six agent windows":
                task.get("runOptions", {}).pop("runOn", None)
        serialized = json.dumps(content, indent=2) + "\n"
        if not workspace.exists() or workspace.read_text() != serialized:
            workspace.write_text(serialized)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    storage = Path.home() / "Library/Application Support/AgentLauncher"
    try:
        request = json.loads(args.request.read_text())
        project, cfg = make_config(request, six_agents.mac("screens"), storage)
        if args.dry_run:
            print(json.dumps(cfg, indent=2))
            return 0
        storage.mkdir(parents=True, exist_ok=True)
        # The fixed lock path also prevents overlapping launches for two projects.
        config = storage / "active-layout.json"
        import fcntl
        with (storage / "launch.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("Another layout is still opening. Wait for it to finish.")
            write_workspaces(project, cfg)
            config.write_text(json.dumps(cfg, indent=2) + "\n")
            six_agents.arrange(config)
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, six_agents.subprocess.TimeoutExpired) as exc:
        print(f"Could not arrange the windows: {exc}", file=sys.stderr, flush=True)
        print("If macOS reports an automation permission error, allow Agent Launcher in System Settings → Privacy & Security → Accessibility, and allow System Events under Automation.", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
