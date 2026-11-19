#!/bin/bash
# iPadOS 向けに 1 回コンパイルし、コンパイラの段階ごとの時間（型チェック・SIL・LLVM など）と、
# ファイルごとの型チェック時間の上位を表示する。ビルド時間を減らすときの手がかりにする。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../DistroVE.swiftpm"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
WORK="$(mktemp -d)"
mkdir -p "$WORK/stats"
LIST="$WORK/files.txt"
find Sources -name '*.swift' | sort > "$LIST"
start=$(date +%s)
# iPad と同じ arm64・Debug（最適化なし）。1 プロセスで全体を通す
xcrun --sdk iphoneos swiftc -c -wmo -Onone -gnone \
  -sdk "$SDK" -target "arm64-apple-ios17.0" \
  -module-name AppModule -parse-as-library -swift-version 5 \
  -stats-output-dir "$WORK/stats" \
  -Xfrontend -debug-time-function-bodies \
  -o "$WORK/AppModule.o" $(cat "$LIST") > "$WORK/out.log" 2>&1
status=$?
end=$(date +%s)
elapsed=$((end - start))
echo "1 プロセス（whole module）でのコンパイル: ${elapsed} 秒（終了コード ${status}）"
if [ "${status}" -ne 0 ]; then
  grep -E "error" "$WORK/out.log" | head -20
  exit "${status}"
fi
python3 "$HERE/profile_report.py" "$WORK"
