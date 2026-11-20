"""Package the dependency-free local VS Code extension."""
from pathlib import Path
import json
import zipfile


def main():
    root = Path(__file__).resolve().parent
    source = root / "service-switcher"
    package = json.loads((source / "package.json").read_text())
    version = package["version"]
    output = root / "dist" / f"agent-service-switcher-{version}.vsix"
    output.parent.mkdir(exist_ok=True)
    manifest = f'''<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="agent-service-switcher" Version="{version}" Publisher="agent-windows"/>
    <DisplayName>AI Service Switcher</DisplayName>
    <Description xml:space="preserve">Switch agent windows between Codex, Claude Code and GitHub Copilot.</Description>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.96.0"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui"/>
    </Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>'''
    types = '''<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="json" ContentType="application/json"/>
<Default Extension="js" ContentType="application/javascript"/>
<Default Extension="md" ContentType="text/markdown"/>
<Default Extension="vsixmanifest" ContentType="text/xml"/>
</Types>'''
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("extension.vsixmanifest", manifest)
        archive.writestr("[Content_Types].xml", types)
        for name in ("package.json", "extension.js", "README.md"):
            archive.write(source / name, "extension/" + name)
    print(output)


if __name__ == "__main__":
    main()
