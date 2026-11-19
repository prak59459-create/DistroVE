#!/bin/bash
# iPadOS 向けに 1 回コンパイルし、コンパイラの段階ごとの時間（構文解析・型チェック・SIL・LLVM など）と、
# ファイルごとの型チェック時間の上位を表示する。ビルド時間を減らすときの手がかりにする。
set -uo pipefail
cd "$(dirname "$0")/../DistroVE.swiftpm"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
WORK="$(mktemp -d)"
LIST="$WORK/files.txt"
find Sources -name '*.swift' | sort > "$LIST"
start=$(date +%s)
xcrun --sdk iphonesimulator swiftc -c -wmo -Onone -g0 \
  -sdk "$SDK" -target "${ARCH}-apple-ios17.0-simulator" \
  -module-name AppModule -parse-as-library -swift-version 5 \
  -Xfrontend -stats-output-dir -Xfrontend "$WORK/stats" \
  -Xfrontend -debug-time-function-bodies \
  -o "$WORK/AppModule.o" $(cat "$LIST") > "$WORK/out.log" 2>&1
status=$?
end=$(date +%s)
echo "1 プロセス（whole module）でのコンパイル: $((end - start)) 秒（終了コード $status）"
python3 - "$WORK" <<'PY'
import glob, json, os, re, sys
work = sys.argv[1]
phases = {}
for path in glob.glob(os.path.join(work, "stats", "*.json")):
    with open(path) as f:
        data = json.load(f)
    for key, value in data.items():
        if key.startswith("time.swift.") and key.endswith(".wall"):
            name = key[len("time.swift."):-len(".wall")]
            phases[name] = phases.get(name, 0.0) + float(value)
print("--- 段階ごとの時間（秒） ---")
for name, value in sorted(phases.items(), key=lambda kv: -kv[1])[:12]:
    print(f"{value:8.2f}  {name}")
per_file = {}
pattern = re.compile(r"^([0-9.]+)ms\s+(\S+?\.swift):")
with open(os.path.join(work, "out.log"), errors="replace") as f:
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
PY
exit 0
