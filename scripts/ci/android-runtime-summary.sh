#!/usr/bin/env bash
# 段2の結果まとめ：ステップごとの所要時間と、XCFramework・ステージ済みイメージのサイズを出す。
# 標準出力と、あれば $GITHUB_STEP_SUMMARY の両方に書く。失敗していても出せる範囲で出す。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K="$ROOT/vendor/kernarium"
TIMINGS="${TIMINGS_FILE:-${RUNNER_TEMP:-/tmp}/timings.tsv}"

report() {
  echo "## Android 段2：ランタイムのビルド結果"
  echo
  echo "### ステップごとの所要時間"
  echo
  echo "| ステップ | 秒 | 分 | 終了コード |"
  echo "| --- | ---: | ---: | ---: |"
  if [ -f "$TIMINGS" ]; then
    awk -F'\t' '{ total += $2; printf "| %s | %d | %.1f | %s |\n", $1, $2, $2/60, $3 }
                END { printf "| **合計** | %d | %.1f | |\n", total, total/60 }' "$TIMINGS"
  else
    echo "| （記録なし） | | | |"
  fi
  echo
  echo "### サイズ"
  echo
  echo '```'
  for p in \
    "$K/.build/kernarium-xcframeworks" \
    "$K/.build/andarium-system" \
    "$K/.build/dependencies" \
    "$K/.build/kernarium-runtime-ios-device-android-4k"; do
    if [ -e "$p" ]; then du -sh "$p"; else echo "(なし) ${p#"$ROOT/"}"; fi
  done
  echo
  echo "--- XCFramework ごと ---"
  if [ -d "$K/.build/kernarium-xcframeworks" ]; then
    du -sh "$K/.build/kernarium-xcframeworks"/*.xcframework 2>/dev/null | sort -h
  fi
  echo
  echo "--- ステージ済みイメージのファイル ---"
  if [ -d "$K/.build/andarium-system" ]; then
    find "$K/.build/andarium-system" -type f -exec ls -l {} \; | awk '{ printf "%12d  %s\n", $5, $9 }'
    echo
    echo "（参考）ipa には XCFramework とこのイメージが入る。GitHub リリースの 1 ファイル上限は 2 GiB = 2147483648 バイト"
  fi
  echo
  df -h "$ROOT" | tail -n1
  echo '```'
}

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  report | tee -a "$GITHUB_STEP_SUMMARY"
else
  report
fi
