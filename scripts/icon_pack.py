#!/usr/bin/env python3
"""ChatGPT で作ったアイコンの画像を、アプリの Assets.xcassets に入れる（開発者用。アプリを使う人は作らない）。

Design/Icons/ に置いた画像を読んで、
- シートを切り分ける（sheet-1〜6.png は 8 列 × 6 行、detailed-1〜20.png は 4 列 × 4 行）
- 背景を透明にする（透明でない画像だけ。白地・黒地・市松模様）
- 余白を切り詰め、真ん中に同じ大きさでおさめる
- 単色か色付きかを見分ける（単色は白にして、Assets でテンプレートにする。アプリが文字の色で塗る）
- DistroVE.swiftpm/Assets.xcassets/Icons/ に 1 つずつ画像セットとして書き出す
- アプリのアイコン（app.icon.png）があれば AppIcon を作り、Package.swift の appIcon を .asset("AppIcon") にする
- Design/Icons/preview.png（確認用の一覧）を作り、おかしそうなマスを知らせる

シートの並び順・Assets の中の名前・大きさは scripts/icon_layout.json（Swift のテストが IconCatalog から作る）に従う。
同じ絵が何か所かにあれば、sheet より detailed、detailed より 1 つずつ置いた画像（edit.split.png など）を使う。

使い方: python3 scripts/icon_pack.py      （Pillow と numpy が要る: pip install pillow numpy）
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import sys
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
LAYOUT_PATH = os.path.join(ROOT, "scripts", "icon_layout.json")
SOURCE_DIR = os.path.join(ROOT, "Design", "Icons")
ASSETS_DIR = os.path.join(ROOT, "DistroVE.swiftpm", "Assets.xcassets")
PACKAGE_PATH = os.path.join(ROOT, "DistroVE.swiftpm", "Package.swift")

IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg", ".webp")
# 読むときの長い辺の上限（これより大きい画像は縮めてから扱う）
MAX_INPUT_SIDE = 2048
# 背景の色からの離れ具合（0〜255）が KEY_LOW 以下なら透明、KEY_HIGH 以上なら不透明
KEY_LOW = 14
KEY_HIGH = 64
# この不透明度（0〜255）を超える所を「描いてある」とみなす
ALPHA_THRESHOLD = 10
APP_ICON_SIZE = 1024
GENERATED_FOLDER = "Icons"
XCODE_INFO = {"author": "xcode", "version": 1}


# MARK: - 画像のそろえ


@dataclass
class Icon:
    """書き出す 1 つの絵（RGBA、前乗算なし）。"""

    pixels: np.ndarray
    color: bool
    source: str = ""


def read_rgba(path: str, max_side: int = MAX_INPUT_SIDE) -> np.ndarray:
    with Image.open(path) as opened:
        image = ImageOps.exif_transpose(opened).convert("RGBA")
    if max(image.size) > max_side:
        image.thumbnail((max_side, max_side), Image.LANCZOS)
    return np.array(image, dtype=np.uint8)


def has_transparency(a: np.ndarray) -> bool:
    """透明な所が 2% 以上あれば、背景はもう透明とみなす。"""
    return int((a[..., 3] < 250).sum()) * 50 > a.shape[0] * a.shape[1]


def border_pixels(a: np.ndarray) -> np.ndarray:
    height = a.shape[0]
    parts = [a[0, :, :3], a[height - 1, :, :3]]
    if height > 2:
        parts += [a[1:height - 1, 0, :3], a[1:height - 1, -1, :3]]
    return np.concatenate(parts).astype(np.int32)


def background_colors(a: np.ndarray) -> np.ndarray:
    """縁の色（多い順に 2 色まで）。市松模様（透明のつもりで描かれた背景）なら 2 色になる。"""
    pixels = border_pixels(a)
    bins = pixels // 16
    keys = bins[:, 0] * 256 + bins[:, 1] * 16 + bins[:, 2]
    values, counts = np.unique(keys, return_counts=True)
    order = np.argsort(-counts, kind="stable")
    colors = []
    for rank, index in enumerate(order[:2]):
        if rank > 0 and counts[index] * 100 < len(pixels) * 15:
            break
        members = np.sort(pixels[keys == values[index]], axis=0)
        colors.append(members[len(members) // 2])
    return np.array(colors, dtype=np.int32)


def key_distance(a: np.ndarray, colors: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """いちばん近い背景の色からの離れ具合（各色の差の最大）と、その背景の色の番号。"""
    rgb = a[..., :3].astype(np.int32)
    best = np.abs(rgb - colors[0]).max(axis=2)
    nearest = np.zeros(best.shape, dtype=np.int32)
    for index in range(1, len(colors)):
        distance = np.abs(rgb - colors[index]).max(axis=2)
        closer = distance < best
        best = np.where(closer, distance, best)
        nearest = np.where(closer, index, nearest)
    return np.minimum(best, 255), nearest


def key_alpha(distance: np.ndarray) -> np.ndarray:
    return np.clip((distance.astype(np.float64) - KEY_LOW) / (KEY_HIGH - KEY_LOW), 0.0, 1.0)


def unblend(a: np.ndarray, distance: np.ndarray, colors: np.ndarray, nearest: np.ndarray,
            outside: Optional[np.ndarray] = None) -> np.ndarray:
    """背景の色を引いて、前景の色と不透明度に分ける。outside があれば、その外（False）は不透明のまま残す。"""
    alpha = key_alpha(distance)
    if outside is not None:
        alpha = np.where(outside, alpha, 1.0)
    background = colors[nearest].astype(np.float64)
    rgb = a[..., :3].astype(np.float64)
    restored = (rgb - (1.0 - alpha)[..., None] * background) / np.maximum(alpha, 1e-6)[..., None]
    visible = alpha > 0
    out = np.zeros_like(a)
    out[..., :3] = np.where(visible[..., None], np.clip(np.rint(restored), 0, 255), 0).astype(np.uint8)
    out[..., 3] = np.where(visible, np.rint(alpha * 255), 0).astype(np.uint8)
    return out


def connected_to_border(passable: np.ndarray) -> np.ndarray:
    """縁からつながった passable の所（上下左右に広げていく）。"""
    reached = np.zeros_like(passable)
    reached[0, :] = passable[0, :]
    reached[-1, :] |= passable[-1, :]
    reached[:, 0] |= passable[:, 0]
    reached[:, -1] |= passable[:, -1]
    while True:
        before = reached
        for _ in range(8):
            grown = reached.copy()
            grown[1:, :] |= reached[:-1, :]
            grown[:-1, :] |= reached[1:, :]
            grown[:, 1:] |= reached[:, :-1]
            grown[:, :-1] |= reached[:, 1:]
            grown &= passable
            reached = grown
        if np.array_equal(before, reached):
            return reached


def is_colorful(a: np.ndarray) -> bool:
    """色付きか（不透明な所のうち、はっきり色の付いた画素が 15% より多い）。"""
    opaque = a[..., 3] > 128
    count = int(opaque.sum())
    if count == 0:
        return False
    rgb = a[..., :3].astype(np.int32)
    high = rgb.max(axis=2)
    low = rgb.min(axis=2)
    colored = opaque & (high > 40) & (high - low > 60)
    return int(colored.sum()) * 100 > count * 15


def remove_background(a: np.ndarray, colors: Optional[np.ndarray] = None,
                      transparent: Optional[bool] = None) -> tuple[np.ndarray, bool]:
    """背景を透明にする。戻り値は（絵, 色付きか）。transparent・colors はシート全体で調べたものを渡せる。"""
    if transparent is None:
        transparent = has_transparency(a)
    if transparent:
        return a.copy(), is_colorful(a)
    if colors is None:
        colors = background_colors(a)
    distance, nearest = key_distance(a, colors)
    keyed = unblend(a, distance, colors, nearest)
    colorful = is_colorful(keyed)
    if colorful and float(colors.mean(axis=1).max()) > 128:
        # 明るい地の色付きの絵は、縁からつながった背景だけを消す（囲まれた白い所は絵の一部として残す）。
        # 暗い地（黒地のネオンなど）は、囲まれた所も背景として消す
        outside = connected_to_border(distance < KEY_HIGH)
        keyed = unblend(a, distance, colors, nearest, outside)
    return keyed, colorful


def bounds(a: np.ndarray, threshold: int = ALPHA_THRESHOLD) -> Optional[tuple[int, int, int, int]]:
    """描いてある所を囲む範囲（x0, y0, x1, y1。x1・y1 は含まない）。"""
    mask = a[..., 3] > threshold
    rows = np.flatnonzero(mask.any(axis=1))
    columns = np.flatnonzero(mask.any(axis=0))
    if rows.size == 0:
        return None
    return int(columns[0]), int(rows[0]), int(columns[-1]) + 1, int(rows[-1]) + 1


def resized(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    """縮めるときは面積の平均、広げるときは双三次（RGBA は Pillow が前乗算して計算する）。"""
    shrinking = size[0] < image.size[0] or size[1] < image.size[1]
    return image.resize(size, Image.BOX if shrinking else Image.BICUBIC)


def fit(a: np.ndarray, box: tuple[int, int, int, int], size: int, fill: float) -> np.ndarray:
    """box の中身を、size × size の真ん中に、長い辺が size × fill になるようにおさめる。"""
    x0, y0, x1, y1 = box
    crop = Image.fromarray(a[y0:y1, x0:x1], "RGBA")
    scale = size * fill / max(crop.size)
    width = max(1, int(round(crop.size[0] * scale)))
    height = max(1, int(round(crop.size[1] * scale)))
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(resized(crop, (width, height)), ((size - width) // 2, (size - height) // 2))
    return np.array(canvas, dtype=np.uint8)


def whiten(a: np.ndarray) -> np.ndarray:
    """単色の絵は白にして、形（不透明度）だけを残す（アプリが色を塗る）。"""
    out = a.copy()
    out[..., :3] = 255
    return out


def square_icon(cleaned: np.ndarray, colorful: bool, size: int, fill: float) -> Optional[Icon]:
    """背景を消した絵を、正方形の真ん中におさめる。何も描いていなければ None。"""
    box = bounds(cleaned)
    if box is None:
        return None
    fitted = fit(cleaned, box, size, fill)
    return Icon(fitted if colorful else whiten(fitted), colorful)


def process_square(a: np.ndarray, size: int, fill: float, colors: Optional[np.ndarray] = None,
                   transparent: Optional[bool] = None) -> Optional[Icon]:
    """1 つのアイコン（正方形）。何も描いていなければ None。"""
    if a.shape[0] < 2 or a.shape[1] < 2:
        return None
    cleaned, colorful = remove_background(a, colors, transparent)
    return square_icon(cleaned, colorful, size, fill)


def process_wide(a: np.ndarray, max_side: int) -> Optional[Icon]:
    """横長のロゴ：余白を切り詰め、形（縦横比）はそのままに長い辺を max_side にする。"""
    cleaned, colorful = remove_background(a)
    box = bounds(cleaned)
    if box is None:
        return None
    x0, y0, x1, y1 = box
    crop = Image.fromarray(cleaned[y0:y1, x0:x1], "RGBA")
    scale = max_side / max(crop.size)
    size = (max(1, int(round(crop.size[0] * scale))), max(1, int(round(crop.size[1] * scale))))
    out = np.array(resized(crop, size), dtype=np.uint8)
    return Icon(out if colorful else whiten(out), colorful)


def flattened(image: Image.Image, color: tuple[int, int, int] = (0, 0, 0)) -> Image.Image:
    """透明な所を color で埋める。"""
    base = Image.new("RGBA", image.size, color + (255,))
    base.alpha_composite(image.convert("RGBA"))
    return base.convert("RGB")


def process_backdrop(a: np.ndarray, max_side: int) -> Icon:
    """背景：そのまま（透明な所は黒）。長い辺を max_side までにする。"""
    image = Image.fromarray(a, "RGBA")
    if max(image.size) > max_side:
        image.thumbnail((max_side, max_side), Image.LANCZOS)
    return Icon(np.array(flattened(image).convert("RGBA"), dtype=np.uint8), True)


def process_app_icon(a: np.ndarray, opaque: bool) -> Image.Image:
    """アプリのアイコン：真ん中を正方形に切り抜いて 1024×1024 にする。opaque なら透明な所を黒で埋める。"""
    image = Image.fromarray(a, "RGBA")
    side = min(image.size)
    left = (image.size[0] - side) // 2
    top = (image.size[1] - side) // 2
    image = image.crop((left, top, left + side, top + side))
    if side != APP_ICON_SIZE:
        image = image.resize((APP_ICON_SIZE, APP_ICON_SIZE), Image.LANCZOS)
    return flattened(image) if opaque else image


# MARK: - シートの切り分け


def cuts(mass, parts: int) -> list[int]:
    """parts 個に分ける切れ目（両端を含む）。等分の位置の近くで、いちばん中身の少ない所を選ぶ。"""
    length = len(mass)
    result = [0]
    cell = length / parts
    for k in range(1, max(1, parts)):
        expected = int(math.floor(k * cell + 0.5))
        reach = max(1, int(cell * 0.3))
        best, best_mass, best_distance = expected, None, None
        lower = max(result[-1] + 1, expected - reach)
        upper = min(length - 1, expected + reach)
        for x in range(lower, upper + 1):
            distance = abs(x - expected)
            value = mass[x]
            if best_mass is None or value < best_mass or (value == best_mass and distance < best_distance):
                best, best_mass, best_distance = x, value, distance
        result.append(best)
    result.append(length)
    return result


@dataclass
class SlicedSheet:
    cells: list[np.ndarray]
    xs: list[int]
    ys: list[int]
    transparent: bool
    colors: Optional[np.ndarray]
    column_mass: np.ndarray
    row_mass: np.ndarray


def slice_sheet(a: np.ndarray, rows: int, columns: int) -> SlicedSheet:
    """rows × columns に並べた 1 枚を切り分ける（左上から右へ、行ごと）。すき間（何も無い列・行）を探して切る。"""
    transparent = has_transparency(a)
    colors = None
    if transparent:
        alpha = a[..., 3].astype(np.int64)
    else:
        colors = background_colors(a)
        distance, _ = key_distance(a, colors)
        alpha = np.rint(key_alpha(distance) * 255).astype(np.int64)
    column_mass = alpha.sum(axis=0)
    row_mass = alpha.sum(axis=1)
    xs = cuts(column_mass, columns)
    ys = cuts(row_mass, rows)
    cells = [a[ys[r]:ys[r + 1], xs[c]:xs[c + 1]] for r in range(rows) for c in range(columns)]
    return SlicedSheet(cells, xs, ys, transparent, colors, column_mass, row_mass)


# MARK: - ファイルを探す


def file_key(text: str) -> str:
    """名前を比べる形（小文字にして英数字だけ残す）。Swift のテストが、どの絵もこの形で重ならないことを確かめている。"""
    return "".join(ch for ch in text.lower() if ch.isascii() and ch.isalnum())


def stem_of(name: str) -> str:
    stem = name
    lower = stem.lower()
    for extension in IMAGE_EXTENSIONS:
        if lower.endswith(extension):
            stem = stem[: -len(extension)]
            break
    for suffix in ("@1x", "@2x", "@3x"):
        if stem.lower().endswith(suffix):
            stem = stem[: -len(suffix)]
    # 先頭の番号（01_ や 1- など）
    match = re.match(r"^\d+[_\- .](.+)$", stem)
    if match:
        stem = match.group(1)
    return stem


def id_for_file(name: str, ids: list[str]) -> Optional[str]:
    """edit.split.png・edit_split.PNG・07_Edit-Split@2x.png などを edit.split とみなす。"""
    stem = stem_of(name)
    if stem in ids:
        return stem
    keys = {file_key(i): i for i in ids}
    return keys.get(file_key(stem))


SHEET_NAME = re.compile(r"^(sheet|detailed)[-_ ]?(\d+)$", re.IGNORECASE)
APP_ICON_KEYS = {"appicon": "main", "appicondark": "dark", "appicontinted": "tinted"}


@dataclass
class Sources:
    sheets: dict[str, dict[int, str]] = field(default_factory=lambda: {"six": {}, "detailed": {}})
    singles: dict[str, str] = field(default_factory=dict)
    app_icon: dict[str, str] = field(default_factory=dict)
    unknown: list[str] = field(default_factory=list)
    duplicates: list[str] = field(default_factory=list)


def find_sources(folder: str, layout: dict) -> Sources:
    found = Sources()
    if not os.path.isdir(folder):
        return found
    ids = [icon["id"] for icon in layout["icons"] if icon["shape"] != "appIcon"]
    prefixes = {entry["prefix"]: name for name, entry in layout["layouts"].items()}
    paths = []
    for directory, _, names in os.walk(folder):
        for name in names:
            if name.lower().endswith(IMAGE_EXTENSIONS) and not name.startswith("."):
                paths.append(os.path.join(directory, name))
    for path in sorted(paths):
        name = os.path.basename(path)
        relative = os.path.relpath(path, folder)
        if name.lower() == "preview.png":
            continue
        stem = stem_of(name)
        match = SHEET_NAME.match(stem)
        if match:
            kind = prefixes[match.group(1).lower()]
            index = int(match.group(2)) - 1
            if index in found.sheets[kind]:
                found.duplicates.append(relative)
            else:
                found.sheets[kind][index] = path
            continue
        app = APP_ICON_KEYS.get(file_key(stem))
        if app:
            if app in found.app_icon:
                found.duplicates.append(relative)
            else:
                found.app_icon[app] = path
            continue
        icon_id = id_for_file(name, ids)
        if icon_id is None:
            found.unknown.append(relative)
        elif icon_id in found.singles:
            found.duplicates.append(relative)
        else:
            found.singles[icon_id] = path
    return found


# MARK: - まとめて作る


@dataclass
class Report:
    icons: dict[str, Icon] = field(default_factory=dict)
    app_icon: dict[str, Image.Image] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    read: list[str] = field(default_factory=list)
    package_updated: bool = False

    def warn(self, text: str) -> None:
        self.warnings.append(text)


def load_layout(path: str = LAYOUT_PATH) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def read_sheet(path: str, label: str, entry: dict, names: list[str], info: dict[str, dict],
               fill: float, report: Report) -> None:
    a = read_rgba(path)
    rows, columns = entry["rows"], entry["columns"]
    expected = entry["width"] / entry["height"]
    actual = a.shape[1] / a.shape[0]
    if abs(actual - expected) > 0.05:
        report.warn(f"{label}: 大きさが {a.shape[1]}×{a.shape[0]} でした（{entry['width']}×{entry['height']} のつもり）。"
                    f"{columns} 列 × {rows} 行として切り分けます。")
    sheet = slice_sheet(a, rows, columns)
    if sheet.colors is not None and len(sheet.colors) > 1:
        report.warn(f"{label}: 背景が市松模様でした（透明のつもりで描かれた背景）。消しましたが、白い線が欠けることがあります。"
                    "透明の PNG で作り直すと確実です。")
    for axis, positions, mass in (("列", sheet.xs, sheet.column_mass), ("行", sheet.ys, sheet.row_mass)):
        peak = float(mass.max()) if mass.size else 0.0
        for position in positions[1:-1]:
            if peak > 0 and float(mass[position]) > peak * 0.02:
                report.warn(f"{label}: {axis}の切れ目（{position} px）に絵がかかっています。マスの数や並びがずれているかもしれません。")
                break
    made_here: list[tuple[str, Icon]] = []
    for position, cell in enumerate(sheet.cells):
        row, column = position // columns + 1, position % columns + 1
        where = f"{label} の {row} 行 {column} 列目"
        cleaned, colorful = remove_background(cell, sheet.colors, sheet.transparent)
        box = bounds(cleaned)
        if position >= len(names):
            if box is not None:
                report.warn(f"{where}: 空けるはずのマスに絵があります。数か順番がずれているかもしれません。")
            continue
        icon_id = names[position]
        if box is None:
            report.warn(f"{where}（{icon_id}）: 絵がありません。")
            continue
        if box[0] == 0 or box[1] == 0 or box[2] >= cell.shape[1] or box[3] >= cell.shape[0]:
            report.warn(f"{where}（{icon_id}）: 絵がマスの端に触れています。切れているか、隣の絵と重なっているかもしれません。")
        made = square_icon(cleaned, colorful, info[icon_id]["size"], fill)
        if made is None:
            continue
        made.source = f"{label} r{row}c{column}"
        made_here.append((icon_id, made))
    match_sheet_style(label, made_here, report)
    for icon_id, made in made_here:
        report.icons[icon_id] = made
    report.read.append(f"{label}（{columns}×{rows}）: {len(made_here)} 個")


def match_sheet_style(label: str, icons: list[tuple[str, Icon]], report: Report) -> None:
    """シートの 9 割以上が単色なら、残りも単色にそろえる。
    単色の絵柄でも、色のにじみを描いた絵（RGB のずれなど）が色付きと見えることがある。色付きのまま出すと、
    白い線がライトモードで見えなくなるので、シートに合わせて単色（アプリが文字の色で塗る）にする。"""
    colored = [icon_id for icon_id, icon in icons if icon.color]
    if not colored or (len(icons) - len(colored)) * 10 < len(icons) * 9:
        return
    for _, icon in icons:
        if icon.color:
            icon.pixels = whiten(icon.pixels)
            icon.color = False
    report.notes.append(f"{label}: 色付きと見えた {len(colored)} 個（{'、'.join(colored)}）を、シートのほかの絵に合わせて単色にしました。")


def read_single(path: str, icon_id: str, info: dict, fill: float, report: Report) -> None:
    relative = os.path.basename(path)
    a = read_rgba(path)
    shape = info["shape"]
    if shape == "wide":
        made = process_wide(a, info["size"])
    elif shape == "backdrop":
        made = process_backdrop(a, info["size"])
    else:
        made = process_square(a, info["size"], fill)
    if made is None:
        report.warn(f"{relative}: 絵がありません（透明か、背景と同じ色だけでした）。")
        return
    made.source = "single"
    report.icons[icon_id] = made
    report.read.append(f"{relative}: {icon_id}")


def build(source: str = SOURCE_DIR, assets: str = ASSETS_DIR, package: Optional[str] = PACKAGE_PATH,
          preview: Optional[str] = None, layout: Optional[dict] = None) -> Report:
    layout = layout or load_layout()
    info = {icon["id"]: icon for icon in layout["icons"]}
    fill = float(layout.get("fill", 0.84))
    report = Report()
    found = find_sources(source, layout)
    for relative in found.unknown:
        report.warn(f"{relative}: 名前が一覧に無いので使いません（docs/アイコン制作プロンプト.md の「9. 全部の一覧」の名前にしてください）。")
    for relative in found.duplicates:
        report.warn(f"{relative}: 同じ絵の画像がほかにもあるので使いません。")
    # シート（6 枚）→ 細かいシート → 1 つずつの順に読み、あとのものを優先する
    for kind in ("six", "detailed"):
        entry = layout["layouts"][kind]
        for index in sorted(found.sheets[kind]):
            path = found.sheets[kind][index]
            label = f"{entry['prefix']}-{index + 1}"
            if index >= len(entry["sheets"]):
                report.warn(f"{os.path.basename(path)}: {entry['prefix']} は {len(entry['sheets'])} 枚までです。")
                continue
            read_sheet(path, label, entry, entry["sheets"][index], info, fill, report)
    for icon_id, path in sorted(found.singles.items()):
        read_single(path, icon_id, info[icon_id], fill, report)
    for variant, path in sorted(found.app_icon.items()):
        report.app_icon[variant] = process_app_icon(read_rgba(path), opaque=variant == "main")
        report.read.append(f"{os.path.basename(path)}: アプリのアイコン（{variant}）")
    if "main" not in report.app_icon and report.app_icon:
        report.warn("app.icon.png が無いので、ダーク用・色付け用だけでは AppIcon を作りません。")
        report.app_icon = {}
    write_assets(assets, report, info)
    if package and "main" in report.app_icon:
        report.package_updated = use_asset_app_icon(package)
    if preview:
        write_preview(preview, report, layout)
    return report


# MARK: - 書き出し


def write_json(path: str, value: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(value, indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n")


def write_assets(assets: str, report: Report, info: dict) -> None:
    """Assets.xcassets/Icons/ を作り直す（このスクリプトが作ったものだけ。AppIcon は app.icon.png があるときだけ書き直す）。"""
    generated = os.path.join(assets, GENERATED_FOLDER)
    if os.path.isdir(generated):
        shutil.rmtree(generated)
    if not report.icons and not report.app_icon:
        return
    os.makedirs(generated, exist_ok=True)
    if not os.path.exists(os.path.join(assets, "Contents.json")):
        write_json(os.path.join(assets, "Contents.json"), {"info": XCODE_INFO})
    write_json(os.path.join(generated, "Contents.json"), {"info": XCODE_INFO})
    for icon_id, icon in sorted(report.icons.items()):
        asset = info[icon_id]["asset"]
        folder = os.path.join(generated, asset + ".imageset")
        os.makedirs(folder)
        image = Image.fromarray(icon.pixels, "RGBA")
        if info[icon_id]["shape"] == "backdrop":
            filename = asset + ".jpg"
            image.convert("RGB").save(os.path.join(folder, filename), quality=90, optimize=True, progressive=True)
        else:
            filename = asset + ".png"
            image.save(os.path.join(folder, filename), optimize=True)
        write_json(os.path.join(folder, "Contents.json"), {
            "images": [
                {"idiom": "universal", "scale": "1x"},
                {"idiom": "universal", "scale": "2x"},
                {"filename": filename, "idiom": "universal", "scale": "3x"},
            ],
            "info": XCODE_INFO,
            "properties": {"template-rendering-intent": "original" if icon.color else "template"},
        })
    if "main" in report.app_icon:
        folder = os.path.join(assets, "AppIcon.appiconset")
        if os.path.isdir(folder):
            shutil.rmtree(folder)
        os.makedirs(folder)
        images = []
        for variant, filename, appearance in (("main", "AppIcon.png", None), ("dark", "AppIcon-Dark.png", "dark"),
                                              ("tinted", "AppIcon-Tinted.png", "tinted")):
            image = report.app_icon.get(variant)
            if image is None:
                continue
            image.save(os.path.join(folder, filename), optimize=True)
            entry = {"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
            if appearance:
                entry = {"appearances": [{"appearance": "luminosity", "value": appearance}], **entry}
            images.append(entry)
        write_json(os.path.join(folder, "Contents.json"), {"images": images, "info": XCODE_INFO})


def use_asset_app_icon(package: str) -> bool:
    """Package.swift の appIcon を Assets の AppIcon にする（Swift Playgrounds の App Settings で選んだときと同じ書き方）。"""
    with open(package, encoding="utf-8") as f:
        text = f.read()
    updated = re.sub(r"appIcon: \.placeholder\(icon: \.[A-Za-z]+\)", 'appIcon: .asset("AppIcon")', text)
    if updated == text:
        return False
    with open(package, "w", encoding="utf-8") as f:
        f.write(updated)
    return True


# MARK: - 確認用の一覧（preview.png）

TILE_WIDTH = 132
TILE_HEIGHT = 128
MARGIN = 16
DARK = (28, 28, 30)
PAGE = (12, 12, 14)
LABEL = (174, 174, 178)
ACCENT = (255, 122, 26)
MISSING = (255, 69, 58)


def font(size: int):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def thumbnail(icon: Icon, side: int) -> Image.Image:
    image = Image.fromarray(icon.pixels, "RGBA")
    image.thumbnail((side, side), Image.LANCZOS)
    return image


def write_preview(path: str, report: Report, layout: dict) -> None:
    """6 枚の画像と同じ並び（8 列）で、できた絵と名前を並べる。右上の小さな絵は道具バーの大きさ（20pt）の見え方。"""
    entry = layout["layouts"]["six"]
    columns = entry["columns"]
    info = {icon["id"]: icon for icon in layout["icons"]}
    small, regular, title = font(10), font(12), font(18)
    sections = []
    for index, names in enumerate(entry["sheets"]):
        sections.append((f"sheet-{index + 1}.png  ({len(names)})", names))
    rows_total = sum(math.ceil(len(names) / columns) for _, names in sections)
    brand_height = 260
    width = MARGIN * 2 + columns * TILE_WIDTH
    height = MARGIN + len(sections) * 40 + rows_total * TILE_HEIGHT + brand_height + MARGIN
    page = Image.new("RGB", (width, height), PAGE)
    draw = ImageDraw.Draw(page)
    y = MARGIN
    for heading, names in sections:
        draw.text((MARGIN, y + 8), heading, fill=(255, 255, 255), font=title)
        y += 40
        for position, icon_id in enumerate(names):
            x = MARGIN + (position % columns) * TILE_WIDTH
            top = y + (position // columns) * TILE_HEIGHT
            box = (x + 4, top + 4, x + TILE_WIDTH - 4, top + TILE_HEIGHT - 4)
            icon = report.icons.get(icon_id)
            outline = MISSING if icon is None else (ACCENT if icon.source == "single" or icon.source.startswith("detailed") else None)
            draw.rounded_rectangle(box, radius=10, fill=DARK, outline=outline, width=2 if outline else 0)
            if icon is None:
                draw.text((x + 14, top + 34), "missing", fill=MISSING, font=regular)
            else:
                big = thumbnail(icon, 64)
                page.paste(big, (x + (TILE_WIDTH - big.size[0]) // 2, top + 14), big)
                mini = thumbnail(icon, 20)
                page.paste(mini, (x + TILE_WIDTH - 30, top + 10), mini)
                if icon.source:
                    draw.text((x + 10, top + 84), icon.source, fill=LABEL, font=small)
            draw.text((x + 10, top + 100), icon_id[:22], fill=(255, 255, 255), font=small)
        y += math.ceil(len(names) / columns) * TILE_HEIGHT
    # ロゴ・背景・アプリのアイコン
    draw.text((MARGIN, y + 8), "brand.logo / brand.background / app.icon", fill=(255, 255, 255), font=title)
    y += 40
    x = MARGIN
    for icon_id, side in (("brand.logo", 360), ("brand.background", 280)):
        icon = report.icons.get(icon_id)
        if icon is None:
            draw.rounded_rectangle((x, y, x + 200, y + 60), radius=10, fill=DARK, outline=MISSING, width=2)
            draw.text((x + 12, y + 22), f"{icon_id}: missing", fill=MISSING, font=regular)
            x += 216
            continue
        image = thumbnail(icon, side)
        draw.rounded_rectangle((x, y, x + image.size[0] + 16, y + image.size[1] + 16), radius=10, fill=DARK)
        page.paste(image, (x + 8, y + 8), image)
        x += image.size[0] + 32
    app = report.app_icon.get("main")
    if app is None:
        draw.rounded_rectangle((x, y, x + 200, y + 60), radius=10, fill=DARK, outline=MISSING, width=2)
        draw.text((x + 12, y + 22), "app.icon: missing", fill=MISSING, font=regular)
    else:
        image = app.copy()
        image.thumbnail((180, 180), Image.LANCZOS)
        mask = Image.new("L", image.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.size[0] - 1, image.size[1] - 1), radius=int(image.size[0] * 0.22), fill=255)
        page.paste(image.convert("RGB"), (x, y), mask)
    page.save(path, optimize=True)


# MARK: - 実行


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="ChatGPT で作ったアイコンを Assets.xcassets に入れる")
    parser.add_argument("--source", default=SOURCE_DIR, help="画像を置いたフォルダー（Design/Icons）")
    parser.add_argument("--assets", default=ASSETS_DIR, help="書き出す Assets.xcassets")
    parser.add_argument("--package", default=PACKAGE_PATH, help="アプリの Package.swift（AppIcon を使うように書き換える）")
    parser.add_argument("--preview", default=None, help="確認用の一覧の画像（省略すると <source>/preview.png）")
    args = parser.parse_args(argv)
    if not os.path.isdir(args.source):
        print(f"{args.source} がありません。ChatGPT で作った画像をここに置いてください。", file=sys.stderr)
        return 1
    preview = args.preview or os.path.join(args.source, "preview.png")
    report = build(args.source, args.assets, args.package, preview)
    layout = load_layout()
    squares = [icon["id"] for icon in layout["icons"] if icon["shape"] == "square"]
    for line in report.read:
        print("読んだ画像  " + line)
    mono = sum(1 for icon in report.icons.values() if not icon.color)
    print(f"書き出した絵: {len(report.icons)} 個（単色 {mono}・色付き {len(report.icons) - mono}）→ {args.assets}")
    missing = [icon_id for icon_id in squares if icon_id not in report.icons]
    if missing:
        shown = "、".join(missing[:12]) + (" など" if len(missing) > 12 else "")
        print(f"絵が無い所（SF Symbols のまま）: {len(missing)} か所  {shown}")
    if "main" in report.app_icon:
        print("アプリのアイコン: AppIcon を作りました" + ("（Package.swift を .asset(\"AppIcon\") にしました）" if report.package_updated else ""))
    for note in report.notes:
        print("そろえた所  " + note)
    for warning in report.warnings:
        print("気になる所  " + warning)
    print(f"確認用の一覧: {preview}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
