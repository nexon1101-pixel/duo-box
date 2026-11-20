#!/usr/bin/env bash
# Kernarium をピン（ios/kernarium.pin）の通りに取得し、Releases の成果物を展開して、
# ピン先ツリーの accepted env と一致するか照合する。
# 取得物は vendor/kernarium（.gitignore 済み）に置き、Kernarium のソースは変更しない。
# 認証: GITHUB_TOKEN（または GH_TOKEN）があれば使う。トークンはファイルに書かない。
#
# 使い方: scripts/ci/fetch-kernarium.sh [--verify-only]
#   --verify-only  取得済みの vendor/kernarium と .build を、ピンと照合するだけ（ダウンロードしない）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="$ROOT/ios/kernarium.pin"
REPO="${KERNARIUM_REPO:-imxieyi/Kernarium}"
DEST="$ROOT/vendor/kernarium"
VERIFY_ONLY=0
[ "${1:-}" = "--verify-only" ] && VERIFY_ONLY=1

fail() { echo "エラー: $*" >&2; exit 1; }

# --- ピンを読む（source せず、決まったキーだけ取り出す） ---
[ -f "$PIN" ] || fail "ピンファイルがありません: $PIN"
KERNARIUM_REF=""
KERNARIUM_RELEASE_TAG=""
while IFS='=' read -r key value; do
  case "$key" in
    KERNARIUM_REF) KERNARIUM_REF="$value" ;;
    KERNARIUM_RELEASE_TAG) KERNARIUM_RELEASE_TAG="$value" ;;
  esac
done < <(grep -E '^[A-Z_]+=' "$PIN")
[[ "$KERNARIUM_REF" =~ ^[0-9a-f]{40}$ ]] || fail "KERNARIUM_REF は 40 桁のコミット SHA にしてください: '$KERNARIUM_REF'"
[[ "$KERNARIUM_RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || fail "KERNARIUM_RELEASE_TAG が不正です: '$KERNARIUM_RELEASE_TAG'"
echo "ピン: ref=$KERNARIUM_REF tag=$KERNARIUM_RELEASE_TAG"

export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# --- 1. Kernarium をピンのコミットで浅く取得 ---
if [ "$VERIFY_ONLY" = 0 ]; then
  rm -rf "$DEST"
  mkdir -p "$DEST"
  git -C "$DEST" init -q
  git -C "$DEST" remote add origin "https://github.com/$REPO.git"
  git -C "$DEST" fetch -q --depth 1 origin "$KERNARIUM_REF"
  git -C "$DEST" checkout -q --detach FETCH_HEAD
fi
GOT="$(git -C "$DEST" rev-parse HEAD)"
[ "$GOT" = "$KERNARIUM_REF" ] || fail "vendor/kernarium のコミット($GOT)がピン($KERNARIUM_REF)と違います"
echo "Kernarium: $REPO @ $GOT"

# --- 2. ピン先の accepted env を読む（source せず値だけ取り出す） ---
read_env() { # ファイル キー
  local line
  line="$(grep -E "^$2=" "$1" | head -n1)" || true
  [ -n "$line" ] || fail "$1 に $2 がありません"
  line="${line#*=}"
  line="${line#\'}"
  line="${line%\'}"
  printf '%s' "$line"
}
KENV="$DEST/kernel/mainline-6.18/artifacts/accepted-android-4k.env"
LENV="$DEST/android/lineage-24/metadata/accepted-release.env"
[ -f "$KENV" ] || fail "ピン先に kernel/mainline-6.18/artifacts/accepted-android-4k.env がありません"
[ -f "$LENV" ] || fail "ピン先に android/lineage-24/metadata/accepted-release.env がありません"
KERNEL_DIR_NAME="$(read_env "$KENV" UML_KERNEL_ARTIFACT_DIRECTORY_NAME)"
KERNEL_RELEASE_ID="$(read_env "$KENV" UML_KERNEL_ARTIFACT_RELEASE_ID)"
LINEAGE_DIR_NAME="$(read_env "$LENV" LINEAGE24_ACCEPTED_DIRECTORY_NAME)"
LINEAGE_RELEASE_ID="$(read_env "$LENV" LINEAGE24_ACCEPTED_RELEASE_ID)"
for v in "$KERNEL_DIR_NAME" "$LINEAGE_DIR_NAME"; do
  [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || fail "accepted env のディレクトリ名が不正です: '$v'"
done
echo "期待（カーネル）: $KERNEL_DIR_NAME (release id $KERNEL_RELEASE_ID)"
echo "期待（Lineage）:  $LINEAGE_DIR_NAME (release id $LINEAGE_RELEASE_ID)"

KERNEL_ROOT="$DEST/.build/kernel/artifacts"
LINEAGE_ROOT="$DEST/.build/android/releases"

# 展開した tar の中身から、ちょうど 1 つの最上位ディレクトリを取り出す
single_top_dir() { # 展開先ディレクトリ
  local entries=("$1"/* "$1"/.[!.]*)
  local found=()
  local e
  for e in "${entries[@]}"; do [ -e "$e" ] && found+=("$e"); done
  [ "${#found[@]}" -eq 1 ] && [ -d "${found[0]}" ] && [ ! -L "${found[0]}" ] || return 1
  printf '%s' "${found[0]}"
}

if [ "$VERIFY_ONLY" = 0 ]; then
  # --- 3. Releases から成果物を取得 ---
  command -v gh >/dev/null || fail "gh コマンドが必要です"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  DL="$WORK/download"
  mkdir -p "$DL"
  gh release download "$KERNARIUM_RELEASE_TAG" --repo "$REPO" --dir "$DL" \
    --pattern 'android-6.18-*.tar.gz' --pattern 'lineage24-*.tar.gz'

  count_one() { # パターン
    local files=("$DL"/$1)
    [ -e "${files[0]}" ] || fail "Releases($KERNARIUM_RELEASE_TAG) に $1 がありません"
    [ "${#files[@]}" -eq 1 ] || fail "Releases($KERNARIUM_RELEASE_TAG) に $1 が複数あります: ${files[*]##*/}"
    printf '%s' "${files[0]}"
  }
  KERNEL_TGZ="$(count_one 'android-6.18-*.tar.gz')"
  LINEAGE_TGZ="$(count_one 'lineage24-*.tar.gz')"
  echo "ダウンロード: $(basename "$KERNEL_TGZ") ($(du -h "$KERNEL_TGZ" | cut -f1)), $(basename "$LINEAGE_TGZ") ($(du -h "$LINEAGE_TGZ" | cut -f1))"

  # --- 4. 展開（最上位ディレクトリ名を照合してから所定の場所へ） ---
  place() { # tgz 期待ディレクトリ名 置き先ルート 種別
    local tgz="$1" expected="$2" root="$3" label="$4"
    local ex="$WORK/extract-$label" top
    mkdir -p "$ex"
    # 絶対パスや .. を含むアーカイブは拒否する
    if tar -tzf "$tgz" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
      fail "$label のアーカイブに不正なパスが含まれています"
    fi
    tar -xzf "$tgz" -C "$ex"
    if ! top="$(single_top_dir "$ex")"; then
      echo "アーカイブの最上位:" >&2; ls -A "$ex" >&2
      fail "$label のアーカイブは、最上位がディレクトリ 1 つの形ではありません（期待: $expected）"
    fi
    if [ "$(basename "$top")" != "$expected" ]; then
      fail "$label の成果物名が一致しません: アーカイブ内 '$(basename "$top")' / ピン先の accepted env '$expected'（Kernarium のコミットと Releases タグがずれています）"
    fi
    mkdir -p "$root"
    mv "$top" "$root/$expected"
  }
  place "$KERNEL_TGZ" "$KERNEL_DIR_NAME" "$KERNEL_ROOT" kernel
  # Lineage は本元の install-release.py で検証付きに置く（全パーティションのハッシュまで確認される）
  LX="$WORK/lineage-stage"
  place "$LINEAGE_TGZ" "$LINEAGE_DIR_NAME" "$LX" lineage
  command -v python3 >/dev/null || fail "python3 が必要です"
  mkdir -p "$LINEAGE_ROOT"
  python3 -I "$DEST/android/lineage-24/tools/install-release.py" \
    --source "$LX/$LINEAGE_DIR_NAME" --destination-root "$LINEAGE_ROOT" \
    || fail "install-release.py の検証に失敗しました（成果物がピン先の accepted-release.env と合っていません）"
fi

# --- 5. 照合 ---
[ -d "$KERNEL_ROOT/$KERNEL_DIR_NAME" ] || fail "カーネル成果物がありません: .build/kernel/artifacts/$KERNEL_DIR_NAME"
[ -d "$LINEAGE_ROOT/$LINEAGE_DIR_NAME" ] || fail "Lineage 成果物がありません: .build/android/releases/$LINEAGE_DIR_NAME"
for d in "$KERNEL_ROOT" "$LINEAGE_ROOT"; do
  n="$(find "$d" -mindepth 1 -maxdepth 1 | wc -l)"
  [ "$n" -eq 1 ] || fail "$d に想定外のものが入っています（$n 個）"
done
echo "照合 OK: 成果物はピン先の accepted env と一致しました"
echo "--- サイズ ---"
du -sh "$KERNEL_ROOT/$KERNEL_DIR_NAME" "$LINEAGE_ROOT/$LINEAGE_DIR_NAME"
