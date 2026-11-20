"""Point Claude Code, Codex and GitHub Copilot hooks at Reply Clock.

    python3 install_hooks.py            add the hooks (or bring them up to date)
    python3 install_hooks.py --remove   take them out again

- Claude Code: Reply Clock entries among the hooks in ~/.claude/settings.json.
- Codex: Reply Clock entries in ~/.codex/hooks.json. Codex runs new hooks only once you trust
  them (/hooks in the Codex CLI, or Settings > Hooks in the Codex app).
- Copilot: a file of its own, ~/.copilot/hooks/reply-clock.json.

Whatever else those files hold is kept, and a file is backed up before it changes. A hook
only tells the overlay app which state its window is in; it never blocks or changes a chat.
"""
from datetime import datetime
import json
from pathlib import Path
import shutil
import sys

HOME = Path.home()
BINARY = HOME / "Applications/ReplyClock.app/Contents/MacOS/ReplyClock"
# (event, matcher): the matcher keeps a hook from running where its event cannot matter.
CLAUDE_EVENTS = (("UserPromptSubmit", None), ("Stop", None), ("PermissionRequest", None),
                 ("Notification", "permission_prompt|elicitation_dialog"),
                 ("PreToolUse", "AskUserQuestion"), ("PostToolUse", None))
CODEX_EVENTS = ("UserPromptSubmit", "Stop", "PermissionRequest", "PreToolUse", "PostToolUse")
# Copilot runs in one host that all VS Code windows share. sessionStart and userPromptSubmitted tie a
# session to the window it was typed in; permissionRequest is left out because Copilot runs it for
# every tool decision (Reply Clock reads the prompts Copilot really shows from its session log).
COPILOT_EVENTS = ("sessionStart", "userPromptSubmitted", "preToolUse", "postToolUse", "agentStop")


def command(service, event):
    return f'"{BINARY}" --hook {service} {event}'


def write(path, data):
    text = json.dumps(data, indent=2) + "\n"
    if path.exists():
        if path.read_text() == text:
            return False
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_name(path.name + ".before-reply-clock-" + stamp))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return True


def update(path, service, groups):
    """Replace this service's Reply Clock entries in a hooks file with `groups` (event -> group).

    Claude Code's settings and Codex's hooks.json share the shape {"hooks": {event: [group]}},
    a group being {"matcher"?, "hooks": [handler]}. An empty `groups` only removes.
    """
    if not path.exists() and not groups:
        return False
    data = json.loads(path.read_text()) if path.exists() else {}
    hooks = data.get("hooks", {})

    def is_ours(handler):
        text = handler.get("command", "")
        return "ReplyClock" in text and f"--hook {service} " in text

    for event in list(dict.fromkeys([*hooks, *groups])):
        kept = []
        for group in hooks.get(event, []):
            handlers = [h for h in group.get("hooks", []) if not is_ours(h)]
            if handlers:
                kept.append({**group, "hooks": handlers})
        if event in groups:
            kept.append(groups[event])
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)
    return write(path, data)


def claude(remove=False, path=HOME / ".claude/settings.json"):
    groups = {}
    for event, matcher in () if remove else CLAUDE_EVENTS:
        # Quiet, and never an error: a hook that fails must not disturb the chat.
        group = {"hooks": [{"type": "command", "timeout": 5,
                            "command": command("claude", event) + " 2>/dev/null || true"}]}
        groups[event] = {"matcher": matcher, **group} if matcher else group
    return update(path, "claude", groups)


def codex(remove=False, path=HOME / ".codex/hooks.json"):
    groups = {event: {"hooks": [{"type": "command", "command": command("codex", event), "timeout": 5}]}
              for event in (() if remove else CODEX_EVENTS)}
    return update(path, "codex", groups)


def copilot(remove=False, path=HOME / ".copilot/hooks/reply-clock.json"):
    if remove:
        existed = path.exists()
        path.unlink(missing_ok=True)
        return existed
    data = {"version": 1, "hooks": {
        event: [{"type": "command", "bash": command("copilot", event), "timeoutSec": 5}]
        for event in COPILOT_EVENTS}}
    return write(path, data)


def main():
    remove = "--remove" in sys.argv[1:]
    if not remove and not BINARY.is_file():
        raise SystemExit(f"Build Reply Clock first (ReplyClock/build.sh): {BINARY} is missing.")
    done = "removed" if remove else "updated"
    same = "none there" if remove else "already set"
    print("Claude Code hooks:", done if claude(remove) else same, "-", HOME / ".claude/settings.json")
    print("Codex hooks:", done if codex(remove) else same, "-", HOME / ".codex/hooks.json")
    print("Copilot hooks:", done if copilot(remove) else same, "-", HOME / ".copilot/hooks/reply-clock.json")
    if not remove:
        print("Codex runs new hooks only after you trust them: /hooks in the Codex CLI, or Settings > Hooks.")
        print("Chats that are already open pick the hooks up after their window is reloaded.")


if __name__ == "__main__":
    main()
