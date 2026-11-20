import json
import unittest

from launcher_config import CHAT_BINDING, PROVIDER_BINDINGS, configure_provider_bindings, add_chat_binding, clean_jsonc, remove_automatic_layout


class ConfigurationTests(unittest.TestCase):
    def test_append_preserves_existing_jsonc_and_escapes(self):
        for source in (
            "// Header\n[\n]\n",
            '[{"key":"ctrl+h","args":"https://example.com/,]"}] // tail ]\n',
            '[{"key":"ctrl+h",}, // trailing comment\n] /* ] */',
            '[/* comment */ {"key":"ctrl+h"} /* comment */]\n',
        ):
            with self.subTest(source=source):
                before = json.loads(clean_jsonc(source))
                result = add_chat_binding(source)
                self.assertEqual(json.loads(clean_jsonc(result)), before + [CHAT_BINDING])
                self.assertEqual(add_chat_binding(result), result)
                if "// Header" in source: self.assertIn("// Header", result)

    def test_existing_shortcut_conflicts_are_preserved(self):
        source = '[{"key":"cmd+alt+shift+9","command":"other.command"}]'
        with self.assertRaises(ValueError): add_chat_binding(source)

    def test_removes_only_the_automatic_layout_trigger(self):
        ours = {"label": "Open and tile six agent windows", "runOptions": {"runOn": "folderOpen", "instanceLimit": 1}}
        other = {"label": "User task", "runOptions": {"runOn": "folderOpen"}}
        content = {"tasks": {"tasks": [ours, other]}}
        remove_automatic_layout(content)
        self.assertEqual(ours["runOptions"], {"instanceLimit": 1})
        self.assertEqual(other["runOptions"]["runOn"], "folderOpen")

    def test_chat_binding_uses_idempotent_commands_and_no_new_chat(self):
        self.assertIn("config.window.title", CHAT_BINDING["when"])
        self.assertEqual(CHAT_BINDING["args"]["commands"], ["agentWindows.restoreService"])
        self.assertEqual([b["args"]["commands"][0] for b in PROVIDER_BINDINGS],
                         ["agentWindows.useCodex", "agentWindows.useClaude", "agentWindows.useCopilot"])

    def test_provider_binding_upgrade_and_preservation(self):
        old = dict(CHAT_BINDING, args={"commands": ["chatgpt.openSidebar"]})
        source = '// Keep this comment\n' + json.dumps([{"key": "ctrl+h", "command": "mine"}, old])
        updated = configure_provider_bindings(source)
        values = json.loads(clean_jsonc(updated))
        self.assertEqual(values, [{"key": "ctrl+h", "command": "mine"}, CHAT_BINDING, *PROVIDER_BINDINGS])
        self.assertIn("// Keep this comment", updated)
        self.assertEqual(json.loads(clean_jsonc(configure_provider_bindings(updated))), values)

    def test_provider_binding_comments_and_trailing_commas(self):
        source = '[{"key":"ctrl+h","command":"mine"}, // Comment\n]'
        values = json.loads(clean_jsonc(configure_provider_bindings(source)))
        self.assertEqual(values[1:], [CHAT_BINDING, *PROVIDER_BINDINGS])


if __name__ == "__main__": unittest.main()
