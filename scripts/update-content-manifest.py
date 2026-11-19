#!/usr/bin/env python3
"""content/ の中身から content/manifest.json を作り直す（ハッシュとサイズを計算する）。
アプリはこの一覧を GitHub から取得し、ハッシュが変わったファイルだけをダウンロードする。"""
import hashlib
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "content")
KINDS = {"templates": "template", "luts": "lut"}


def main() -> int:
    files = []
    for folder, kind in KINDS.items():
        base = os.path.join(ROOT, folder)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if not os.path.isfile(path) or name.startswith("."):
                continue
            with open(path, "rb") as f:
                data = f.read()
            files.append({
                "path": f"{folder}/{name}",
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
                "kind": kind,
            })
    manifest_path = os.path.join(ROOT, "manifest.json")
    version = 1
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as f:
            old = json.load(f)
        version = int(old.get("version", 0))
        if old.get("files") != files:
            version += 1
    manifest = {"version": version, "minimumAppVersion": "0.1.0", "files": files}
    if "--check" in sys.argv:
        with open(manifest_path, encoding="utf-8") as f:
            current = json.load(f)
        if current.get("files") != files:
            print("content/manifest.json が古いです。scripts/update-content-manifest.py を実行してください。")
            return 1
        print("content/manifest.json は最新です")
        return 0
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"manifest.json を更新しました（{len(files)} 件、版 {version}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
