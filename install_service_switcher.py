"""Install the AI Service Switcher extension into VS Code, with its key bindings.

    python3 install_service_switcher.py

The key bindings (launcher_config.py) apply only in agent windows; keybindings.json is backed
up before it changes.
"""
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess

from launcher_config import configure_provider_bindings
from six_agents import code_cli


def main():
    root = Path(__file__).resolve().parent
    version = json.loads((root / "service-switcher/package.json").read_text())["version"]
    package = root / f"dist/agent-service-switcher-{version}.vsix"
    if not package.is_file():
        raise SystemExit("Build the service switcher first: python3 build_service_switcher.py")
    bindings = Path.home() / "Library/Application Support/Code/User/keybindings.json"
    original = bindings.read_text() if bindings.exists() else "[]"
    updated = configure_provider_bindings(original)
    # Run from a VS Code terminal, these variables would send the CLI to the wrong place.
    env = os.environ.copy()
    env.pop("VSCODE_IPC_HOOK_CLI", None)
    env.pop("ELECTRON_RUN_AS_NODE", None)
    subprocess.run([code_cli("com.microsoft.VSCode"), "--install-extension", str(package), "--force"],
                   env=env, check=True, timeout=90)
    if original != updated:
        if bindings.exists():
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            shutil.copy2(bindings, bindings.with_name(bindings.name + ".before-service-switcher-" + stamp))
        bindings.parent.mkdir(parents=True, exist_ok=True)
        bindings.write_text(updated)
    print("Installed the AI Service Switcher. Reload open VS Code windows to load it.", flush=True)


if __name__ == "__main__":
    main()
