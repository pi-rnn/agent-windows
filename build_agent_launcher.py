"""Build the local macOS application without downloading dependencies."""
from pathlib import Path
import hashlib
import plistlib
import shutil
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent
    binary = root / "AgentLauncher/AgentLauncher"
    if not binary.exists() or binary.stat().st_mtime < (root / "AgentLauncher/main.swift").stat().st_mtime:
        subprocess.run(["/usr/bin/swiftc", str(root / "AgentLauncher/main.swift"), "-o", str(binary),
                        "-module-cache-path", "/private/tmp/agent-launcher-swift-cache"], check=True)
    app = root / "dist/Agent Launcher.app"
    resources = app / "Contents/Resources"
    macos = app / "Contents/MacOS"
    resources.mkdir(parents=True, exist_ok=True)
    macos.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, macos / "AgentLauncher")
    for name in ("six_agents.py", "agent_launcher.py"):
        shutil.copy2(root / name, resources / name)
    info = {
        "CFBundleIdentifier": "local.agentlauncher",
        "CFBundleName": "Agent Launcher", "CFBundleDisplayName": "Agent Launcher",
        "CFBundleExecutable": "AgentLauncher", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "2", "CFBundleShortVersionString": "1.1",
        "CFBundleIconFile": "AgentLauncher.icns",
        "NSHighResolutionCapable": True, "LSMinimumSystemVersion": "12.0",
        "NSAppleEventsUsageDescription": "Agent Launcher uses System Events to move and resize your VS Code agent windows on the displays you choose.",
        # The backend needs only the standard library: any Python 3.9+ will do.
        "AgentPythonExecutable": sys.executable,
    }
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    icon = root / "AgentLauncher/icon.png"
    previous_icon = hashlib.sha256(icon.read_bytes()).digest() if icon.exists() else None
    subprocess.run([str(binary), "--render-icon", str(icon)], check=True)
    if previous_icon == hashlib.sha256(icon.read_bytes()).digest() and (resources / "AgentLauncher.icns").is_file():
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
        print(app)
        return
    iconset = root / "AgentLauncher/AgentLauncher.iconset"
    iconset.mkdir(exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
            subprocess.run(["/usr/bin/sips", "-z", str(size * scale), str(size * scale), str(icon),
                            "--out", str(iconset / name)], check=True, capture_output=True)
    subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(resources / "AgentLauncher.icns")], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
