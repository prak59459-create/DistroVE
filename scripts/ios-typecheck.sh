#!/bin/bash
# iPadOS SDK で全ソース（Core / Engine / UI / App）を型チェックし、時間のかかる関数を報告する。
# macOS（Xcode が入った環境）で実行する。
set -uo pipefail
cd "$(dirname "$0")/../DistroVE.swiftpm"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
LOG="$(mktemp)"
LIST="$(mktemp)"
find Sources -name '*.swift' | sort > "$LIST"
echo "対象ファイル: $(wc -l < "$LIST" | tr -d ' ') 個 / $(cat "$LIST" | xargs cat | wc -l | tr -d ' ') 行"
# 基準：アプリが使うフレームワークを読み込むだけの時間
BASE="$(mktemp -d)/Imports.swift"
cat > "$BASE" <<'SWIFT'
import Accelerate
import AVFoundation
import AVKit
import Combine
import CoreImage
import CoreText
import CryptoKit
import ImageIO
import Metal
import MetricKit
import PencilKit
import PhotosUI
import ReplayKit
import Speech
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision
SWIFT
start=$(date +%s)
xcrun --sdk iphonesimulator swiftc -typecheck -sdk "$SDK" -target "${ARCH}-apple-ios17.0-simulator" "$BASE" > /dev/null 2>&1
end=$(date +%s)
echo "フレームワークの読み込みだけ（初回）: $((end - start)) 秒"
start=$(date +%s)
xcrun --sdk iphonesimulator swiftc -typecheck -sdk "$SDK" -target "${ARCH}-apple-ios17.0-simulator" "$BASE" > /dev/null 2>&1
end=$(date +%s)
echo "フレームワークの読み込みだけ（2 回目）: $((end - start)) 秒"

start=$(date +%s)
xcrun --sdk iphonesimulator swiftc -typecheck \
  -sdk "$SDK" -target "${ARCH}-apple-ios17.0-simulator" \
  -module-name AppModule -parse-as-library -swift-version 5 \
  -Xfrontend -warn-long-function-bodies=150 \
  -Xfrontend -warn-long-expression-type-checking=150 \
  $(cat "$LIST") > "$LOG" 2>&1
status=$?
end=$(date +%s)
grep -E "error:" "$LOG" | head -150
echo "--- 型チェックに時間のかかった関数（150ms 超） ---"
grep -E "took [0-9]+ms to type-check" "$LOG" | sed 's/^.*Sources\///' | sort -u | head -40
echo "--- 警告の数: $(grep -c 'warning:' "$LOG") ---"
# どんな警告か（同じものは 1 回だけ）
grep -E "warning:" "$LOG" | sed 's/^.*Sources\///' | sort -u | head -20
echo "型チェック（1 プロセス）: $((end - start)) 秒"
exit $status
