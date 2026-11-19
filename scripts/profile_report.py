#!/usr/bin/env python3
"""ios-profile.sh の結果（コンパイラの統計 JSON と -debug-time-function-bodies の出力）をまとめて表示する。

使い方: profile_report.py <作業フォルダー>
  <作業フォルダー>/stats/*.json … -stats-output-dir の出力
  <作業フォルダー>/out.log      … -debug-time-function-bodies の出力（1 行 1 関数）
"""
import glob
import json
import os
import re
import sys

# 入れ子になっていない、大きな段階だけを表示する（入れ子の計測を足すと二重に数えるため）
PHASES = [
    ("Type checking and Semantic analysis", "型チェック"),
    ("SILGen", "SIL の生成"),
    ("SIL optimization", "SIL の最適化"),
    ("IRGen", "LLVM IR の生成"),
    ("LLVM pipeline", "LLVM（機械語の生成）"),
    ("SIL-and-LLVM-processing", "SIL と LLVM の処理（合計）"),
]


def main() -> int:
    work = sys.argv[1]
    totals = {}
    frontend_total = 0.0
    for path in glob.glob(os.path.join(work, "stats", "*.json")):
        with open(path) as f:
            data = json.load(f)
        for key, value in data.items():
            if not key.endswith(".wall"):
                continue
            if key.startswith("time.swift-frontend."):
                frontend_total += float(value)
            elif key.startswith("time.swift."):
                name = key[len("time.swift."):-len(".wall")]
                totals[name] = totals.get(name, 0.0) + float(value)
    print("--- コンパイラの段階ごとの時間（秒） ---")
    if frontend_total > 0:
        print(f"{frontend_total:8.2f}  全体（コンパイラ本体）")
    for key, label in PHASES:
        if key in totals:
            print(f"{totals[key]:8.2f}  {label}")
    per_file = {}
    pattern = re.compile(r"^([0-9.]+)ms\s+(\S+?\.swift):")
    log = os.path.join(work, "out.log")
    if os.path.exists(log):
        with open(log, errors="replace") as f:
            for line in f:
                m = pattern.match(line.strip())
                if m:
                    ms, path = float(m.group(1)), m.group(2)
                    key = path.split("Sources/")[-1]
                    per_file[key] = per_file.get(key, 0.0) + ms
    print("--- 関数本体の型チェックが重いファイル（ミリ秒） ---")
    for key, value in sorted(per_file.items(), key=lambda kv: -kv[1])[:15]:
        print(f"{value:8.0f}  {key}")
    print(f"合計: {sum(per_file.values()):.0f} ms")
    if frontend_total == 0 and not per_file:
        print("統計が取れませんでした")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
