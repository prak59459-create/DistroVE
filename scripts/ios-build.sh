#!/bin/bash
# Swift Playgrounds と同じ App パッケージ（DistroVE.swiftpm）を xcodebuild でビルドし、
# クリーンビルドと差分ビルド（1 ファイル変更）の時間を測る。目標 10 秒・上限 60 秒。
set -uo pipefail
cd "$(dirname "$0")/../DistroVE.swiftpm"
DERIVED="$(mktemp -d)"
LOG="$(mktemp)"
xcodebuild -list 2>&1 | head -30
SCHEME="Distro VE"
DEST="generic/platform=iOS Simulator"

start=$(date +%s)
xcodebuild build -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO -showBuildTimingSummary > "$LOG" 2>&1
status=$?
end=$(date +%s)
clean=$((end - start))
grep -E "error:" "$LOG" | head -100
echo "--- ビルド時間の内訳 ---"
sed -n '/Build Timing Summary/,$p' "$LOG" | grep -E "Swift|Compile|Link|Ld|Total|seconds" | head -20
grep -E "BUILD (SUCCEEDED|FAILED)" "$LOG" | tail -1
echo "クリーンビルド: ${clean} 秒"

if [ $status -eq 0 ]; then
  echo "// build-time check $(date +%s)" >> Sources/App/DistroVEApp.swift
  start=$(date +%s)
  xcodebuild build -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO -quiet > /dev/null 2>&1
  end=$(date +%s)
  incremental=$((end - start))
  git checkout -- Sources/App/DistroVEApp.swift 2>/dev/null || true
  echo "差分ビルド（1 ファイル変更）: ${incremental} 秒"
  echo "::notice title=ビルド時間::クリーン ${clean} 秒 / 差分 ${incremental} 秒（目標 10 秒・上限 60 秒）"
  if [ "$clean" -gt 60 ]; then
    echo "::warning title=ビルド時間::クリーンビルドが上限の 60 秒を超えました（${clean} 秒）"
  fi
fi
exit $status
