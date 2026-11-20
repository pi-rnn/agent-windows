import unittest

from six_agents import choose_screen, fits_cell, layout_cells, on_screen


class LayoutTests(unittest.TestCase):
    def test_leftmost_screen_uses_display_coordinates(self):
        screens = [{"frame": {"x": 0, "y": 0}},
                   {"frame": {"x": -2560, "y": -7}},
                   {"frame": {"x": -4000, "y": -142}}]
        self.assertIs(choose_screen(screens), screens[2])

    def test_portrait_cells_cover_left_display_in_reading_order(self):
        rect = {"x": -4000, "y": -142, "width": 1440, "height": 2560}
        cells = list(layout_cells(rect))
        self.assertEqual([a for a, _ in cells], [
            "top-left-sixth", "top-right-sixth", "top-center-sixth",
            "bottom-center-sixth", "bottom-left-sixth", "bottom-right-sixth"])
        self.assertEqual([(c["x"], c["y"]) for _, c in cells], [
            (-4000, -142), (-3280, -142), (-4000, 711),
            (-3280, 711), (-4000, 1565), (-3280, 1565)])
        self.assertEqual(sum(c["width"] * c["height"] for _, c in cells), 1440 * 2560)
        for _, cell in cells:
            window = {"position": [cell["x"], cell["y"]],
                      "size": [cell["width"], cell["height"]]}
            self.assertTrue(fits_cell(window, cell))
            self.assertTrue(on_screen(window, rect))

    def test_landscape_still_uses_three_columns(self):
        cells = list(layout_cells({"x": -2560, "y": 25, "width": 2560, "height": 1379}))
        self.assertEqual([c["y"] for _, c in cells[:3]], [25, 25, 25])
        self.assertEqual(cells[-1][1]["x"] + cells[-1][1]["width"], 0)
        self.assertEqual(cells[-1][1]["y"] + cells[-1][1]["height"], 1404)

    def test_validation_rejects_original_fullscreen_failure(self):
        rect = {"x": -4000, "y": -142, "width": 1440, "height": 2560}
        _, cell = next(layout_cells(rect))
        window = {"position": [-2560, -7], "size": [2560, 1440], "fullscreen": True}
        self.assertFalse(fits_cell(window, cell))
        self.assertFalse(on_screen(window, rect))
        window = {"position": [cell["x"], cell["y"]],
                  "size": [cell["width"], cell["height"]], "fullscreen": True}
        self.assertFalse(fits_cell(window, cell))


if __name__ == "__main__":
    unittest.main()
