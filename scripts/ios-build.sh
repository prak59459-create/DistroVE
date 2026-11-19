#!/bin/bash
# Swift Playgrounds と同じ App パッケージ（DistroVE.swiftpm）を xcodebuild でビルドし、時間を測る。
#   1. 初回ビルド        … SDK（SwiftUI・AVFoundation など）のモジュールキャッシュ作りを含む。端末で最初の 1 回だけ
#   2. クリーンビルド    … モジュールキャッシュがある状態で、アプリのコードだけを全部作り直す
#   3. 差分ビルド        … 1 ファイルだけ変えた、ふだんの「直して実行」。3 回測って中央値を使う
# 目標 10 秒・上限 60 秒（2 と 3 に当てはめる）。
set -uo pipefail
cd "$(dirname "$0")/../DistroVE.swiftpm"
DERIVED="$(mktemp -d)"
LOG="$(mktemp)"
SCHEME="Distro VE"
# iPad 実機と同じ arm64 だけのビルド（シミュレーター向けは 2 つの CPU 向けに作るため時間が倍になる）
DEST="generic/platform=iOS"
TOUCHED="Sources/UI/Home/SettingsView.swift"

now() { python3 -c 'import time; print("%.2f" % time.time())'; }
# 引数の時刻から今までの秒数（小数 1 桁）
since() { python3 -c 'import sys, time; print("%.1f" % (time.time() - float(sys.argv[1])))' "$1"; }
# 1 つ目の数が 2 つ目より大きいか
over() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)' "$1" "$2"; }

build() {
  xcodebuild build -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO -showBuildTimingSummary "$@" > "$LOG" 2>&1
}

# xcodebuild の作業ごとの時間（-showBuildTimingSummary）
summary() {
  sed -n '/Build Timing Summary/,$p' "$LOG" | grep -E "\| [0-9.]+ seconds" | head -"$1"
}

memory=$(( $(sysctl -n hw.memsize) / 1073741824 ))
echo "Mac: $(sysctl -n machdep.cpu.brand_string) / $(sysctl -n hw.ncpu) コア / ${memory} GB"

start=$(now)
build
status=$?
cold=$(since "$start")
grep -E "error:" "$LOG" | head -100
grep -E "BUILD (SUCCEEDED|FAILED)" "$LOG" | tail -1
echo "1. 初回ビルド（モジュールキャッシュ作成を含む）: ${cold} 秒"
if [ "${status}" -ne 0 ]; then
  tail -40 "$LOG"
  exit "${status}"
fi

xcodebuild clean -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DERIVED" -quiet > /dev/null 2>&1
start=$(now)
build
clean=$(since "$start")
echo "--- クリーンビルドの内訳 ---"
summary 12
echo "2. クリーンビルド（モジュールキャッシュあり）: ${clean} 秒"

runs=()
for i in 1 2 3; do
  echo "// build-time check ${i} $(date +%s)" >> "$TOUCHED"
  start=$(now)
  build
  runs+=("$(since "$start")")
done
git checkout -- "$TOUCHED" 2>/dev/null || true
echo "--- 差分ビルドの内訳（3 回目） ---"
summary 8
incremental=$(printf '%s\n' "${runs[@]}" | sort -n | sed -n 2p)
echo "3. 差分ビルド（1 ファイル変更・3 回の中央値）: ${incremental} 秒（${runs[*]}）"

echo "::notice title=ビルド時間::初回 ${cold} 秒 / クリーン ${clean} 秒 / 差分 ${incremental} 秒（目標 10 秒・上限 60 秒）"
if over "$clean" 60; then
  echo "::warning title=ビルド時間::クリーンビルドが上限の 60 秒を超えました（${clean} 秒）"
fi
if over "$incremental" 10; then
  echo "::warning title=ビルド時間::差分ビルドが目標の 10 秒を超えました（${incremental} 秒）"
fi
exit 0
