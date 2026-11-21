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

# 大きな段階。上の 3 つは重ならず、字下げしたものは「SIL と LLVM の処理」の内側にある
# （Xcode の Swift には「SIL と LLVM の処理」の記録がないことがある。そのときは「型チェック以外」を見る）
PHASES = [
    ("parse-and-resolve-imports", "構文解析と import の読み込み"),
    ("Type checking and Semantic analysis", "型チェック"),
    ("SIL-and-LLVM-processing", "SIL と LLVM の処理（機械語まで）"),
    ("SILGen", "  SIL の生成"),
    ("SIL-processing", "  SIL の処理"),
    ("IRGen", "  LLVM IR の生成"),
]
KNOWN = {key for key, _ in PHASES}
# 型チェックの内側の計測（上の段階と二重に数えるので「その他」には出さない）
NESTED = {
    "perform-sema", "typecheck-stmt", "typecheck-expr", "typecheck-decl", "typecheck-expr-pattern",
    "typecheck-for-each", "precheck-target", "SILGen-function", "SIL-mandatory-passes",
    "SIL optimization", "Import resolution", "import-clang-decl", "build-rewrite-system",
}


def read_stats(work):
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
    return frontend_total, totals


def print_phases(frontend_total, totals):
    print("--- コンパイラの段階ごとの時間（秒） ---")
    if frontend_total > 0:
        print(f"{frontend_total:8.2f}  全体（コンパイラ本体）")
    for key, label in PHASES:
        if key in totals:
            print(f"{totals[key]:8.2f}  {label}")
    typecheck = totals.get("Type checking and Semantic analysis")
    if frontend_total > 0 and typecheck is not None:
        print(f"{frontend_total - typecheck:8.2f}  型チェック以外（全体 − 型チェック。import・SIL・LLVM など）")
    others = [(k, v) for k, v in totals.items() if k not in KNOWN and k not in NESTED and v >= 0.1]
    if others:
        print("--- そのほかに記録された段階（秒） ---")
        for key, value in sorted(others, key=lambda kv: -kv[1])[:8]:
            print(f"{value:8.2f}  {key}")


def print_function_bodies(work):
    per_file = {}
    functions = []
    # 例: 42.53ms<TAB>Sources/Core/Formats/CubeLUT.swift:255:17<TAB>static method AppModule.(file).ToneCurve.table(_:count:)@...
    pattern = re.compile(r"^([0-9.]+)ms\s+(\S+?\.swift):([0-9]+):[0-9]+\s*(.*)$")
    log = os.path.join(work, "out.log")
    if os.path.exists(log):
        with open(log, errors="replace") as f:
            for line in f:
                m = pattern.match(line.strip())
                if m:
                    ms, path = float(m.group(1)), m.group(2)
                    key = path.split("Sources/")[-1]
                    per_file[key] = per_file.get(key, 0.0) + ms
                    name = re.sub(r"[A-Za-z]+\.\(file\)\.", "", m.group(4).split("@")[0]).strip()
                    functions.append((ms, f"{key}:{m.group(3)}", name))
    print("--- 関数本体の型チェックが重いファイル（ミリ秒） ---")
    for key, value in sorted(per_file.items(), key=lambda kv: -kv[1])[:15]:
        print(f"{value:8.0f}  {key}")
    print(f"合計: {sum(per_file.values()):.0f} ms")
    print("--- 型チェックが重い関数（ミリ秒。CI は 150 を超えると警告） ---")
    for ms, place, name in sorted(functions, key=lambda item: -item[0])[:12]:
        print(f"{ms:8.1f}  {place}  {name}")
    return per_file


def main() -> int:
    work = sys.argv[1]
    frontend_total, totals = read_stats(work)
    print_phases(frontend_total, totals)
    per_file = print_function_bodies(work)
    if frontend_total == 0 and not per_file:
        print("統計が取れませんでした")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
