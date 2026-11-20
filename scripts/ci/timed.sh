#!/usr/bin/env bash
# コマンドを実行して、所要時間を $TIMINGS_FILE（既定: $RUNNER_TEMP/timings.tsv）に1行足す。
# 使い方: scripts/ci/timed.sh <ラベル> <コマンド> [引数...]
# コマンドが失敗しても所要時間は記録し、終了コードはそのまま返す。
set -uo pipefail

[ "$#" -ge 2 ] || { echo "使い方: timed.sh <ラベル> <コマンド> [引数...]" >&2; exit 2; }
LABEL="$1"; shift
OUT="${TIMINGS_FILE:-${RUNNER_TEMP:-/tmp}/timings.tsv}"

START=$(date +%s)
echo "::group::$LABEL"
"$@"
RC=$?
echo "::endgroup::"
END=$(date +%s)

printf '%s\t%s\t%s\n' "$LABEL" "$((END - START))" "$RC" >> "$OUT"
echo "[時間] $LABEL: $((END - START)) 秒 (終了コード $RC)"
exit "$RC"
