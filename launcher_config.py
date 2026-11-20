"""Small, reversible configuration changes used by the local installer."""
import json


CHAT_BINDING = {
    "key": "cmd+alt+shift+9",
    "command": "runCommands",
    "when": r"config.window.title =~ /\[(launcher-)?[0-9a-f]{10}\]/",
    "args": {"commands": ["agentWindows.restoreService"]},
}

PROVIDER_BINDINGS = [
    {"key": f"cmd+alt+{index}", "command": "runCommands", "when": CHAT_BINDING["when"],
     "args": {"commands": [command]}}
    for index, command in enumerate(("agentWindows.useCodex", "agentWindows.useClaude", "agentWindows.useCopilot"), 1)
]


def configure_provider_bindings(source):
    """Update only this launcher's bindings, preserving JSONC and user shortcuts."""
    source = source or "[\n]\n"
    for binding in [CHAT_BINDING, *PROVIDER_BINDINGS]:
        clean = clean_jsonc(source)
        entries = json.loads(clean)
        cursor = clean.index("[") + 1
        found = False
        for entry in entries:
            while clean[cursor].isspace() or clean[cursor] == ",": cursor += 1
            _, end = json.JSONDecoder().raw_decode(clean, cursor)
            if entry.get("key") == binding["key"]:
                if entry.get("command") != "runCommands" or entry.get("when") != CHAT_BINDING["when"]:
                    raise ValueError(f"Shortcut already in use: {binding['key']}")
                source = source[:cursor] + json.dumps(binding, indent=4) + source[end:]
                found = True
                break
            cursor = end
        if not found:
            end = len(clean.rstrip()) - 1
            # Insert the comma after the final item, before its trailing comments.
            if entries:
                source = source[:cursor] + "," + source[cursor:]
                end += 1
                # Remove an existing trailing comma through the original clean
                # tail; JSONC permits it, but a second comma would be invalid.
                if "," in clean_jsonc("[0" + source[cursor + 1:end] + "0]")[2:-2]:
                    source = source[:cursor] + source[cursor + 1:]
                    end -= 1
            source = source[:end] + "\n" + json.dumps(binding, indent=4) + "\n" + source[end:]
        json.loads(clean_jsonc(source))
    return source


def clean_jsonc(source):
    """Remove comments/trailing commas while retaining every character offset."""
    output = list(source)
    in_string = False
    index = 0
    while index < len(source):
        char = source[index]
        if in_string:
            if char == "\\": index += 2; continue
            if char == '"': in_string = False
        elif char == '"':
            in_string = True
        elif source.startswith("//", index):
            end = source.find("\n", index)
            if end < 0: end = len(source)
            output[index:end] = " " * (end - index)
            index = end; continue
        elif source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end < 0: raise ValueError("Unclosed comment in VS Code keybindings.")
            end += 2
            output[index:end] = ["\n" if c == "\n" else " " for c in source[index:end]]
            index = end; continue
        index += 1
    stripped = "".join(output)
    in_string = False
    index = 0
    while index < len(stripped):
        char = stripped[index]
        if in_string:
            if char == "\\": index += 2; continue
            if char == '"': in_string = False
        elif char == '"': in_string = True
        elif char == ",":
            following = index + 1
            while following < len(stripped) and stripped[following].isspace(): following += 1
            if following < len(stripped) and stripped[following] in "]}": output[index] = " "
        index += 1
    return "".join(output)


def add_chat_binding(source):
    source = source or "[\n]\n"
    clean = clean_jsonc(source)
    entries = json.loads(clean)
    if not isinstance(entries, list): raise ValueError("VS Code keybindings must be a JSON array.")
    if CHAT_BINDING in entries: return source
    if any(e.get("key", "").lower() == CHAT_BINDING["key"] for e in entries):
        raise ValueError("The Agent Launcher shortcut is already used by another binding; existing bindings were preserved.")
    end = len(clean.rstrip()) - 1
    # clean_jsonc turns a trailing comma into a space. Search its original
    # position only through the whitespace/comment tail after the last item.
    decoder = json.JSONDecoder()
    cursor = clean.index("[") + 1
    item_end = cursor
    for _ in entries:
        while clean[cursor].isspace() or clean[cursor] == ",": cursor += 1
        _, item_end = decoder.raw_decode(clean, cursor)
        cursor = item_end
    tail = source[item_end:end]
    comma_present = "," in clean_jsonc("[0" + tail + "0]")[2:-2] if entries else False
    separator = "," if entries and not comma_present else ""
    binding = json.dumps(CHAT_BINDING, indent=4)
    rendered = "\n".join("    " + line for line in binding.splitlines())
    result = source[:end].rstrip() + separator + "\n    // Agent Launcher: manual chat layout, scoped to its agent windows.\n" + rendered + "\n" + source[end:]
    json.loads(clean_jsonc(result))  # Validate before the installer can write.
    return result


def remove_automatic_layout(content):
    for task in content.get("tasks", {}).get("tasks", []):
        if task.get("label") == "Open and tile six agent windows":
            task.get("runOptions", {}).pop("runOn", None)
    return content
