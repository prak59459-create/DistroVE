#!/bin/bash
# Core（純 Swift の部分）をクリーンビルドし、かかった時間を表示する。
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf .build
start=$(date +%s)
swift build
end=$(date +%s)
elapsed=$((end - start))
echo "Core のクリーンビルド: ${elapsed} 秒（目標 10 秒・上限 60 秒）"
if [ "$elapsed" -gt 60 ]; then
  echo "::warning title=ビルド時間::Core のクリーンビルドが ${elapsed} 秒かかりました（上限 60 秒）"
fi
