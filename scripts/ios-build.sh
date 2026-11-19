#!/bin/bash
# Swift Playgrounds と同じ App パッケージ（DistroVE.swiftpm）を xcodebuild でビルドし、時間を測る。
#   1. 初回ビルド        … SDK（SwiftUI・AVFoundation など）のモジュールキャッシュ作りを含む。端末で最初の 1 回だけ
#   2. クリーンビルド    … モジュールキャッシュがある状態で、アプリのコードだけを全部作り直す
#   3. 差分ビルド        … 1 ファイルだけ変えた、ふだんの「直して実行」
# 目標 10 秒・上限 60 秒（2 と 3 に当てはめる）。
set -uo pipefail
cd "$(dirname "$0")/../DistroVE.swiftpm"
DERIVED="$(mktemp -d)"
LOG="$(mktemp)"
SCHEME="Distro VE"
# iPad 実機と同じ arm64 だけのビルド（シミュレーター向けは 2 つの CPU 向けに作るため時間が倍になる）
DEST="generic/platform=iOS"

build() {
  xcodebuild build -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO -showBuildTimingSummary "$@" > "$LOG" 2>&1
}

start=$(date +%s)
build
status=$?
end=$(date +%s)
cold=$((end - start))
grep -E "error:" "$LOG" | head -100
grep -E "BUILD (SUCCEEDED|FAILED)" "$LOG" | tail -1
echo "1. 初回ビルド（モジュールキャッシュ作成を含む）: ${cold} 秒"
if [ $status -ne 0 ]; then
  tail -40 "$LOG"
  exit $status
fi

xcodebuild clean -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DERIVED" -quiet > /dev/null 2>&1
start=$(date +%s)
build
end=$(date +%s)
clean=$((end - start))
echo "--- クリーンビルドの内訳 ---"
sed -n '/Build Timing Summary/,$p' "$LOG" | grep -E "\| [0-9.]+ seconds" | head -12
echo "2. クリーンビルド（モジュールキャッシュあり）: ${clean} 秒"

echo "// build-time check $(date +%s)" >> Sources/UI/Home/SettingsView.swift
start=$(date +%s)
build
end=$(date +%s)
incremental=$((end - start))
git checkout -- Sources/UI/Home/SettingsView.swift 2>/dev/null || true
echo "3. 差分ビルド（1 ファイル変更）: ${incremental} 秒"

echo "::notice title=ビルド時間::初回 ${cold} 秒 / クリーン ${clean} 秒 / 差分 ${incremental} 秒（目標 10 秒・上限 60 秒）"
if [ "$clean" -gt 60 ]; then
  echo "::warning title=ビルド時間::クリーンビルドが上限の 60 秒を超えました（${clean} 秒）"
fi
exit 0
