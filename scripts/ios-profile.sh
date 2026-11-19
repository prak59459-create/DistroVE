#!/bin/bash
# iPadOS 向けに 1 回コンパイルし、コンパイラの段階ごとの時間（型チェック・SIL・LLVM など）と、
# ファイルごとの型チェック時間の上位を表示する。ビルド時間を減らすときの手がかりにする。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../DistroVE.swiftpm"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
WORK="$(mktemp -d)"
mkdir -p "$WORK/stats" "$WORK/warm"
LIST="$WORK/files.txt"
find Sources -name '*.swift' | sort > "$LIST"
# iPad と同じ arm64・Debug（最適化なし）。1 プロセスで全体を通す
FLAGS=(-c -wmo -Onone -gnone -sdk "$SDK" -target "arm64-apple-ios17.0"
  -module-cache-path "$WORK/modules" -module-name AppModule -parse-as-library -swift-version 5)

# 先に、アプリが import するフレームワークだけを同じ設定で読み込み、SDK のモジュールキャッシュを作っておく。
# 本番の計測にキャッシュ作りの時間が混ざらないようにするため（実際のビルドでもキャッシュは 1 回目だけ作る）
WARM="$WORK/warm/Imports.swift"
grep -rhoE "^import [A-Za-z]+" Sources | sort -u > "$WARM"
start=$(date +%s)
xcrun --sdk iphoneos swiftc "${FLAGS[@]}" -o "$WORK/warm/Imports.o" "$WARM" > "$WORK/warm/out.log" 2>&1
end=$(date +%s)
echo "SDK のモジュールキャッシュ作り（$(wc -l < "$WARM" | tr -d ' ') 個のフレームワーク）: $((end - start)) 秒"

start=$(date +%s)
xcrun --sdk iphoneos swiftc "${FLAGS[@]}" \
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
