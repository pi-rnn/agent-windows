"""Install the built app in ~/Applications and put a shortcut to it on the Desktop.

    python3 install_agent_launcher.py [--no-open] [--launch-last]

Also adds the launcher's key bindings to VS Code (launcher_config.py); they apply only in
agent windows, and keybindings.json is backed up before it changes.
"""
from datetime import datetime
import argparse
from pathlib import Path
import shutil
import subprocess

from launcher_config import configure_provider_bindings


def configure_keybindings():
    keybindings = Path.home() / "Library/Application Support/Code/User/keybindings.json"
    original = keybindings.read_text() if keybindings.exists() else "[\n]\n"
    updated = configure_provider_bindings(original)
    if updated == original:
        return
    if keybindings.exists():
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = keybindings.with_name(keybindings.name + ".before-agent-launcher-" + stamp)
        shutil.copy2(keybindings, backup)
        print("Backup:", backup, flush=True)
    keybindings.parent.mkdir(parents=True, exist_ok=True)
    keybindings.write_text(updated)
    print("Added the agent-window key bindings to VS Code.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-open", action="store_true", help="Do not open the launcher after installing.")
    parser.add_argument("--launch-last", action="store_true", help="Open the saved layout right away.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    source = root / "dist/Agent Launcher.app"
    if not (source / "Contents/MacOS/AgentLauncher").is_file():
        raise SystemExit("Build the application first: python3 build_agent_launcher.py")
    # Never replace a launcher that is in the middle of opening windows.
    if subprocess.run(["/usr/bin/pgrep", "-x", "AgentLauncher"], capture_output=True).returncode == 0:
        raise SystemExit("Agent Launcher is open. Quit it, then run this again.")
    configure_keybindings()
    destination = Path.home() / "Applications/Agent Launcher.app"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)
    print("Installed:", destination)
    desktop = Path.home() / "Desktop/Agent Launcher.app"
    if desktop.is_symlink() and desktop.resolve() == destination.resolve():
        pass
    elif desktop.exists() or desktop.is_symlink():
        print("No Desktop shortcut: another item there is already called Agent Launcher.")
    else:
        desktop.symlink_to(destination, target_is_directory=True)
        print("Desktop shortcut:", desktop)
    if not args.no_open:
        command = ["/usr/bin/open", str(destination)]
        if args.launch_last:
            command += ["--args", "--launch-last"]
        subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
