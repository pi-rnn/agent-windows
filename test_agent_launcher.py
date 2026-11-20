import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import agent_launcher
import six_agents


def screens():
    return [{"id": 1, "name": "Laptop", "frame": {"x": 0, "y": 0, "width": 1512, "height": 982},
             "visible": {"x": 0, "y": 38, "width": 1512, "height": 883}},
            {"id": 2, "name": "Landscape Display", "frame": {"x": -2560, "y": -7, "width": 2560, "height": 1440},
             "visible": {"x": -2560, "y": 18, "width": 2560, "height": 1415}},
            {"id": 3, "name": "Portrait Display", "frame": {"x": -4000, "y": -142, "width": 1440, "height": 2560},
             "visible": {"x": -4000, "y": -117, "width": 1440, "height": 2535}}]


class LauncherTests(unittest.TestCase):
    def test_split_between_external_display_and_laptop(self):
        with tempfile.TemporaryDirectory() as directory:
            request = {"project": directory, "allocations": [{"screen_id": 3, "count": 4}, {"screen_id": 1, "count": 2}]}
            _, cfg = agent_launcher.make_config(request, screens(), Path(directory))
            plan = six_agents.plan_layout(cfg, screens())
            self.assertEqual([s["id"] for s, _, _ in plan], [3, 3, 3, 3, 1, 1])
            self.assertEqual([a for _, a, _ in plan[-2:]], ["left-half", "right-half"])

    def test_disconnect_or_duplicate_display_is_rejected_before_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            for allocations in ([{"screen_id": 99, "count": 2}],
                                [{"screen_id": 1, "count": 1}, {"screen_id": 1, "count": 2}]):
                with self.assertRaises(ValueError):
                    agent_launcher.make_config({"project": directory, "allocations": allocations}, screens(), Path(directory))
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_counts_are_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            for count in (0, -1, 25, True, 2.5):
                with self.assertRaises(ValueError):
                    agent_launcher.make_config({"project": directory, "allocations": [{"screen_id": 1, "count": count}]}, screens(), Path(directory))

    def test_workspace_identity_survives_count_and_screen_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            request = {"project": directory, "allocations": [{"screen_id": 3, "count": 6}]}
            project, old = agent_launcher.make_config(request, screens(), Path(directory))
            agent_launcher.write_workspaces(project, old)
            workspace = Path(old["windows"][0]["workspace"])
            content = json.loads(workspace.read_text())
            self.assertNotIn("tasks", content)
            content["settings"]["editor.fontSize"] = 18
            workspace.write_text(json.dumps(content))
            request["allocations"] = [{"screen_id": 1, "count": 2}]
            _, new = agent_launcher.make_config(request, screens(), Path(directory))
            self.assertEqual(old["windows"][:2], new["windows"])
            agent_launcher.write_workspaces(project, new)
            self.assertEqual(json.loads(workspace.read_text())["settings"]["editor.fontSize"], 18)

    def test_all_supported_grids_stay_on_each_display_without_overlap(self):
        for screen in screens():
            for count in range(1, 25):
                with self.subTest(screen=screen["name"], count=count):
                    cells = [cell for _, cell in six_agents.layout_cells(screen["visible"], count)]
                    self.assertEqual(len(cells), count)
                    for i, cell in enumerate(cells):
                        w = {"position": [cell["x"], cell["y"]], "size": [cell["width"], cell["height"]]}
                        self.assertTrue(six_agents.on_screen(w, screen["visible"]))
                        for other in cells[i + 1:]:
                            overlap = (cell["x"] < other["x"] + other["width"] and other["x"] < cell["x"] + cell["width"]
                                       and cell["y"] < other["y"] + other["height"] and other["y"] < cell["y"] + cell["height"])
                            self.assertFalse(overlap)

    def test_arranger_places_each_window_only_on_its_assigned_display(self):
        with tempfile.TemporaryDirectory() as directory:
            _, cfg = agent_launcher.make_config({"project": directory, "open_chat": False,
                "allocations": [{"screen_id": 3, "count": 2}, {"screen_id": 1, "count": 1}]}, screens(), Path(directory))
            config_file = Path(directory) / "config.json"
            config_file.write_text(json.dumps(cfg))
            windows = {w["marker"]: {"title": w["marker"], "position": [100, 100], "size": [800, 600], "fullscreen": False}
                       for w in cfg["windows"]}
            placed = []
            def fake_mac(operation, **payload):
                if operation == "screens": return screens()
                if operation == "windows": return list(windows.values())
                if operation == "normalize": return {"transition": False}
                if operation == "tile":
                    for item in payload["placements"]:
                        rect = item["rect"]
                        placed.append((item["marker"], dict(rect)))
                        windows[item["marker"]].update(position=[rect["x"], rect["y"]], size=[rect["width"], rect["height"]])
                    return []
                marker = payload["marker"]
                if operation == "place":
                    rect = payload["rect"]
                    placed.append((marker, dict(rect)))
                    windows[marker].update(position=[rect["x"], rect["y"]], size=[rect["width"], rect["height"]])
                return windows[marker]
            with patch.object(six_agents, "mac", side_effect=fake_mac), patch.object(six_agents, "code_cli", return_value="code"), \
                 patch.object(six_agents, "run", return_value=""), patch.object(six_agents.time, "sleep"), contextlib.redirect_stdout(io.StringIO()):
                six_agents.arrange(config_file)
            self.assertEqual(len(placed), 3)
            self.assertTrue(all(cell["x"] < -2560 for _, cell in placed[:2]))
            self.assertEqual(placed[2][1]["x"], 0)

    def test_missing_workspaces_open_in_one_cli_call_and_tile_once(self):
        with tempfile.TemporaryDirectory() as directory:
            _, cfg = agent_launcher.make_config({"project": directory, "open_chat": False,
                "allocations": [{"screen_id": 3, "count": 3}]}, screens(), Path(directory))
            windows = []
            def fake_run(argv, **kwargs):
                self.assertEqual(argv[:2], ["code", "--new-window"])
                self.assertEqual(argv[2:], [w["workspace"] for w in cfg["windows"]])
                windows.extend({"title": w["marker"], "position": [0, 38], "size": [800, 600], "fullscreen": False}
                               for w in cfg["windows"])
                return ""
            def fake_mac(operation, **payload):
                if operation == "screens": return screens()
                if operation == "windows": return windows
                if operation == "tile":
                    for window, target in zip(windows, payload["placements"]):
                        rect = target["rect"]
                        window.update(position=[rect["x"], rect["y"]], size=[rect["width"], rect["height"]])
                    return []
                self.fail(f"Unexpected operation: {operation}")
            with patch.object(six_agents, "mac", side_effect=fake_mac) as mac, \
                 patch.object(six_agents, "code_cli", return_value="code"), \
                 patch.object(six_agents, "run", side_effect=fake_run) as run, \
                 patch.object(six_agents.time, "sleep"), contextlib.redirect_stdout(io.StringIO()):
                six_agents.arrange_once(cfg)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(sum(call.args[0] == "tile" for call in mac.call_args_list), 1)

    def test_chat_only_settings_preserve_existing_editor_preferences(self):
        with tempfile.TemporaryDirectory() as directory:
            project, cfg = agent_launcher.make_config({"project": directory,
                "allocations": [{"screen_id": 1, "count": 1}]}, screens(), Path(directory))
            agent_launcher.write_workspaces(project, cfg)
            file = Path(cfg["windows"][0]["workspace"])
            content = json.loads(file.read_text())
            self.assertTrue(content["settings"]["workbench.secondarySideBar.forceMaximized"])
            self.assertEqual(content["settings"]["workbench.secondarySideBar.defaultVisibility"], "maximized")
            self.assertFalse(content["settings"]["zenMode.fullScreen"])
            self.assertNotIn("tasks", content)


if __name__ == "__main__":
    unittest.main()
