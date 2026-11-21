#!/bin/bash
# Swift Playgrounds と同じ App パッケージ（DistroVE.swiftpm）を xcodebuild でビルドし、時間を測る。
#   1. 初回ビルド        … SDK（SwiftUI・AVFoundation など）のモジュールキャッシュ作りを含む。端末で最初の 1 回だけ
#   2. クリーンビルド    … モジュールキャッシュがある状態で、アプリのコードだけを全部作り直す
#   3. 差分ビルド        … 1 ファイルだけ変えた、ふだんの「直して実行」。3 回測って中央値を使う
#   4. 変更なしのビルド  … 何も変えずにもう一度。xcodebuild 自体の準備と確認にかかる時間
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
if [ "${status}" -ne 0 ]; then
  tail -40 "$LOG"
  exit "${status}"
fi
echo "--- 初回ビルドの内訳 ---"
summary 12
echo "1. 初回ビルド（モジュールキャッシュ作成を含む）: ${cold} 秒"

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
  echo "--- 差分ビルド ${i} 回目の内訳 ---"
  summary 4
done
incremental=$(printf '%s\n' "${runs[@]}" | sort -n | sed -n 2p)
echo "3. 差分ビルド（1 ファイル変更・3 回の中央値）: ${incremental} 秒（${runs[*]}）"

start=$(now)
build
noop=$(since "$start")
git checkout -- "$TOUCHED" 2>/dev/null || true
echo "4. 変更なしのビルド（xcodebuild 自体の準備と確認だけ）: ${noop} 秒"

echo "::notice title=ビルド時間::初回 ${cold} 秒 / クリーン ${clean} 秒 / 差分 ${incremental} 秒 / 変更なし ${noop} 秒（目標 10 秒・上限 60 秒）"
if over "$clean" 60; then
  echo "::warning title=ビルド時間::クリーンビルドが上限の 60 秒を超えました（${clean} 秒）"
fi
if over "$incremental" 10; then
  echo "::warning title=ビルド時間::差分ビルドが目標の 10 秒を超えました（${incremental} 秒）"
fi

# アプリに入れたアイコン（Assets.xcassets）が、アプリ本体（Bundle.main）の Assets.car に入っているか。
# アプリは UIImage(named:) で本体から探すので、別の bundle に入ると SF Symbols のままになる。
if [ -d Assets.xcassets ]; then
  app="$(find "$DERIVED/Build/Products" -maxdepth 2 -name "*.app" -type d | head -1)"
  if [ -z "$app" ] || [ ! -f "$app/Assets.car" ]; then
    echo "::error title=アイコン::アプリ本体に Assets.car がありません（${app:-アプリが見つからない}）"
    find "$DERIVED/Build/Products" -name "Assets.car" | head -5
    exit 1
  fi
  xcrun assetutil --info "$app/Assets.car" > "$LOG.assets" 2> /dev/null
  python3 - "$LOG.assets" Assets.xcassets <<'PY'
import json, os, sys
info = json.load(open(sys.argv[1]))
entries = [e for e in info if isinstance(e, dict) and e.get("AssetType") == "Image"]
names = {e.get("Name") for e in entries}
expected = sorted(n[: -len(".imageset")] for _, dirs, _ in os.walk(sys.argv[2]) for n in dirs if n.endswith(".imageset"))
missing = [n for n in expected if n not in names]
sample = next((e for e in entries if e.get("Name") == "edit_split"), None)
modes = {k: v for k, v in (sample or {}).items() if "emplate" in k or k in ("Name", "Scale", "PixelWidth")}
print(f"--- アイコン: Assets.car（アプリ本体）に {len(expected) - len(missing)} / {len(expected)} 個 {modes} ---")
if missing:
    print("::error title=アイコン::Assets.car に無い絵: " + ", ".join(missing[:10]))
    sys.exit(1)
PY
  [ $? -eq 0 ] || exit 1
fi
exit 0
