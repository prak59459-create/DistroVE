#!/usr/bin/env python3
"""scripts/icon_pack.py のテスト（python3 scripts/test_icon_pack.py。Pillow と numpy が要る）。"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import icon_pack  # noqa: E402

WHITE = (255, 255, 255, 255)
BLACK = (0, 0, 0, 255)
ORANGE = (255, 122, 26, 255)
CLEAR = (0, 0, 0, 0)


def canvas(width: int, height: int, color=WHITE) -> np.ndarray:
    a = np.zeros((height, width, 4), dtype=np.uint8)
    a[:] = color
    return a


def disk(a: np.ndarray, cx: float, cy: float, radius: float, color) -> None:
    yy, xx = np.ogrid[: a.shape[0], : a.shape[1]]
    a[(xx - cx) ** 2 + (yy - cy) ** 2 <= radius * radius] = color


def save(a: np.ndarray, path: str) -> None:
    Image.fromarray(a, "RGBA").save(path)


class ProcessingTests(unittest.TestCase):
    def test_cuts_are_at_the_gaps(self):
        self.assertEqual(icon_pack.cuts([0, 5, 5, 0, 0, 5, 5, 0], 2), [0, 4, 8])

    def test_monochrome_glyph_on_white_becomes_a_centred_white_template(self):
        # 白地に黒い輪。中心をずらして小さめに置く
        a = canvas(200, 200)
        disk(a, 70, 80, 40, BLACK)
        disk(a, 70, 80, 25, WHITE)
        icon = icon_pack.process_square(a, 256, 0.84)
        self.assertIsNotNone(icon)
        self.assertFalse(icon.color)
        self.assertEqual(icon.pixels.shape, (256, 256, 4))
        x0, y0, x1, y1 = icon_pack.bounds(icon.pixels)
        self.assertAlmostEqual((x0 + x1) / 2, 128, delta=2)
        self.assertAlmostEqual((y0 + y1) / 2, 128, delta=2)
        self.assertAlmostEqual(x1 - x0, 256 * 0.84, delta=3)
        # 形だけを残して白にする（アプリが文字の色で塗る）。輪の中と外は透明
        opaque = icon.pixels[..., 3] > 0
        self.assertTrue((icon.pixels[opaque][:, :3] == 255).all())
        self.assertEqual(icon.pixels[128, 128, 3], 0)
        self.assertEqual(icon.pixels[2, 2, 3], 0)

    def test_colour_icon_keeps_its_colours_and_inner_white(self):
        # 白地にオレンジの輪、その中は白（背景と同じ色でも、囲まれているので残す）
        a = canvas(200, 200)
        disk(a, 100, 100, 60, ORANGE)
        disk(a, 100, 100, 30, WHITE)
        icon = icon_pack.process_square(a, 256, 0.84)
        self.assertTrue(icon.color)
        self.assertEqual(icon.pixels[128, 128, 3], 255)
        self.assertTrue((icon.pixels[128, 128, :3] > 245).all())
        self.assertEqual(icon.pixels[3, 3, 3], 0)
        ring = icon.pixels[128, 128 - 75]
        self.assertEqual(ring[3], 255)
        self.assertGreater(int(ring[0]) - int(ring[2]), 150)

    def test_colour_ring_on_black_loses_its_black_inside(self):
        # 黒地にオレンジの輪（ネオンを黒地で描かれたとき）。輪の中の黒も背景なので消す
        a = canvas(200, 200, BLACK)
        disk(a, 100, 100, 60, ORANGE)
        disk(a, 100, 100, 30, BLACK)
        icon = icon_pack.process_square(a, 256, 0.84)
        self.assertTrue(icon.color)
        self.assertEqual(icon.pixels[128, 128, 3], 0)
        self.assertEqual(icon.pixels[128, 128 - 75, 3], 255)

    def test_transparent_input_keeps_its_alpha(self):
        a = canvas(100, 100, CLEAR)
        a[30:70, 30:70] = (255, 255, 255, 128)
        icon = icon_pack.process_square(a, 100, 0.5)
        self.assertFalse(icon.color)
        self.assertAlmostEqual(int(icon.pixels[50, 50, 3]), 128, delta=2)
        self.assertEqual(icon.pixels[5, 5, 3], 0)

    def test_checkerboard_background_is_removed(self):
        # 「透明のつもり」で描かれた市松模様の上の黒い四角
        a = canvas(160, 160)
        yy, xx = np.mgrid[:160, :160]
        a[((yy // 16) + (xx // 16)) % 2 == 1] = (204, 204, 204, 255)
        a[50:110, 60:100] = BLACK
        self.assertEqual(len(icon_pack.background_colors(a)), 2)
        icon = icon_pack.process_square(a, 160, 0.8)
        x0, y0, x1, y1 = icon_pack.bounds(icon.pixels)
        # 残るのは黒い四角だけ（縦長 60×40 のまま）
        self.assertAlmostEqual((x1 - x0) / (y1 - y0), 40 / 60, delta=0.03)
        self.assertFalse(icon.color)

    def test_white_glyph_on_black_is_a_template(self):
        a = canvas(120, 120, BLACK)
        a[40:80, 20:100] = WHITE
        icon = icon_pack.process_square(a, 120, 0.84)
        self.assertFalse(icon.color)
        x0, y0, x1, y1 = icon_pack.bounds(icon.pixels)
        self.assertAlmostEqual((x1 - x0) / (y1 - y0), 2, delta=0.05)

    def test_six_sheet_is_sliced_into_eight_columns_and_six_rows(self):
        # 1536×1024 を 1/4 にした大きさ（マスの高さは割り切れない 42.67）。マスごとに幅を変えて、順番を確かめる
        width, height, columns, rows = 384, 256, 8, 6
        a = canvas(width, height)
        cell_width, cell_height = width / columns, height / rows
        for cell in range(columns * rows):
            column, row = cell % columns, cell // columns
            left = int(column * cell_width) + 8 + cell % 3
            top = int(row * cell_height) + 10
            a[top:top + 20, left:left + 6 + cell % 20] = BLACK
        sheet = icon_pack.slice_sheet(a, rows, columns)
        self.assertEqual(len(sheet.cells), 48)
        for i, cell in enumerate(sheet.cells):
            cleaned, _ = icon_pack.remove_background(cell, sheet.colors, sheet.transparent)
            x0, y0, x1, y1 = icon_pack.bounds(cleaned)
            self.assertEqual(x1 - x0, 6 + i % 20, f"マス {i}")
            self.assertEqual(y1 - y0, 20, f"マス {i}")

    def test_wide_logo_keeps_its_shape(self):
        a = canvas(600, 300)
        a[40:100, 50:350] = BLACK
        icon = icon_pack.process_wide(a, 500)
        self.assertEqual(icon.pixels.shape[:2], (100, 500))
        self.assertGreater(int(icon.pixels[50, 250, 3]), 200)
        self.assertFalse(icon.color)
        self.assertIsNone(icon_pack.process_wide(canvas(10, 10, CLEAR), 500))

    def test_file_names_are_matched_to_ids(self):
        ids = ["edit.split", "edit.rippleDelete", "effect.zoomBlur", "transition.cube3D"]
        self.assertEqual(icon_pack.id_for_file("edit.split.png", ids), "edit.split")
        self.assertEqual(icon_pack.id_for_file("edit_split.PNG", ids), "edit.split")
        self.assertEqual(icon_pack.id_for_file("Edit-Split@2x.png", ids), "edit.split")
        self.assertEqual(icon_pack.id_for_file("07_edit.rippleDelete.png", ids), "edit.rippleDelete")
        self.assertEqual(icon_pack.id_for_file("effect_zoom_blur.webp", ids), "effect.zoomBlur")
        self.assertEqual(icon_pack.id_for_file("transition.cube3D.jpg", ids), "transition.cube3D")
        self.assertIsNone(icon_pack.id_for_file("holiday-photo.png", ids))


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()
        self.source = os.path.join(self.folder, "Icons")
        self.assets = os.path.join(self.folder, "Assets.xcassets")
        self.package = os.path.join(self.folder, "Package.swift")
        self.preview = os.path.join(self.folder, "preview.png")
        os.makedirs(self.source)
        shutil.copy(icon_pack.PACKAGE_PATH, self.package)
        self.layout = icon_pack.load_layout()
        self.info = {icon["id"]: icon for icon in self.layout["icons"]}
        self.names = self.layout["layouts"]["six"]["sheets"][0]

    def tearDown(self):
        shutil.rmtree(self.folder)

    def sheet(self, marks: int) -> np.ndarray:
        """透明な 768×512（1536×1024 の半分）に、左上から marks 個の白い形を並べる。"""
        a = canvas(768, 512, CLEAR)
        for cell in range(marks):
            column, row = cell % 8, cell // 8
            cx = column * 96 + 48
            cy = int(row * 512 / 6 + 512 / 12)
            disk(a, cx, cy, 14 + cell % 12, WHITE)
        return a

    def run_build(self):
        return icon_pack.build(self.source, self.assets, self.package, self.preview, self.layout)

    def contents(self, icon_id: str) -> dict:
        asset = self.info[icon_id]["asset"]
        with open(os.path.join(self.assets, "Icons", asset + ".imageset", "Contents.json"), encoding="utf-8") as f:
            return json.load(f)

    def test_sheet_singles_logo_and_app_icon(self):
        save(self.sheet(len(self.names)), os.path.join(self.source, "sheet-1.png"))
        # 1 つずつ置いた絵は、シートの同じ絵より優先される（色付き）
        single = canvas(300, 300)
        disk(single, 150, 150, 100, ORANGE)
        save(single, os.path.join(self.source, "home.new.png"))
        logo = canvas(900, 600, CLEAR)
        logo[250:350, 150:750] = WHITE
        save(logo, os.path.join(self.source, "brand.logo.png"))
        app = canvas(1100, 1024, ORANGE)
        app[:, :40] = CLEAR
        save(app, os.path.join(self.source, "app.icon.png"))
        save(canvas(10, 10), os.path.join(self.source, "holiday.png"))

        report = self.run_build()
        for icon_id in self.names:
            self.assertIn(icon_id, report.icons, icon_id)
        self.assertEqual(report.icons["home.new"].source, "single")
        self.assertTrue(report.icons["home.new"].color)
        self.assertEqual(report.icons[self.names[1]].source, "sheet-1 r1c2")
        # 単色はテンプレート、色付きはそのまま
        self.assertEqual(self.contents(self.names[1])["properties"]["template-rendering-intent"], "template")
        self.assertEqual(self.contents("home.new")["properties"]["template-rendering-intent"], "original")
        png = os.path.join(self.assets, "Icons", self.info[self.names[1]]["asset"] + ".imageset",
                           self.info[self.names[1]]["asset"] + ".png")
        with Image.open(png) as made:
            self.assertEqual(made.size, (256, 256))
            self.assertEqual(made.mode, "RGBA")
        # ロゴは横長のまま
        self.assertEqual(report.icons["brand.logo"].pixels.shape[:2], (171, 1024))
        # アプリのアイコンは 1024×1024 で透明なし。Package.swift は Assets の AppIcon を使う
        with Image.open(os.path.join(self.assets, "AppIcon.appiconset", "AppIcon.png")) as made:
            self.assertEqual(made.size, (1024, 1024))
            self.assertEqual(made.mode, "RGB")
        self.assertTrue(report.package_updated)
        with open(self.package, encoding="utf-8") as f:
            self.assertIn('appIcon: .asset("AppIcon")', f.read())
        self.assertTrue(any("holiday.png" in w for w in report.warnings))
        self.assertFalse(any("空けるはず" in w or "絵がありません" in w for w in report.warnings), report.warnings)
        self.assertTrue(os.path.exists(self.preview))

        # 置いた画像を消して作り直すと、その絵も消える
        os.remove(os.path.join(self.source, "home.new.png"))
        report = self.run_build()
        self.assertEqual(report.icons["home.new"].source, "sheet-1 r1c1")
        self.assertFalse(report.icons["home.new"].color)

    def test_count_and_order_mistakes_are_reported(self):
        # 46 個のはずが 48 個描かれている（最後の 2 マスに絵がある）
        save(self.sheet(48), os.path.join(self.source, "sheet-1.png"))
        report = self.run_build()
        self.assertEqual(sum("空けるはず" in w for w in report.warnings), 2, report.warnings)
        # 1 つ足りない（最後の絵が無い）
        save(self.sheet(len(self.names) - 1), os.path.join(self.source, "sheet-1.png"))
        report = self.run_build()
        self.assertTrue(any(self.names[-1] in w and "絵がありません" in w for w in report.warnings), report.warnings)
        self.assertNotIn(self.names[-1], report.icons)

    def test_no_images_writes_nothing(self):
        report = self.run_build()
        self.assertEqual(report.icons, {})
        self.assertFalse(os.path.exists(os.path.join(self.assets, "Icons")))
        self.assertFalse(report.package_updated)


if __name__ == "__main__":
    unittest.main()
