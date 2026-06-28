#!/usr/bin/env bash
# doctor フレーム: ツールの導入状況・更新有無・警告を 1 行ずつ表示し、最後に集計と
# 終了コードを返す共通土台。tool 固有のチェックは利用側が組み立て、本ファイルは
# 「行の描画」「バージョン比較」「集計」を担う。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/doctor.sh"
#   booch_doctor_init
#   booch_doctor_tool "go"  "$go_current"  "$go_latest"   # 比較して OK / 更新あり / 不在
#   booch_doctor_row  "cc"  ok  "installed"               # 任意の 1 行
#   booch_doctor_summary                                  # 集計行＋終了コード
#
# status: ok | missing | outdated | warn | skip
#
# 集計状態（公開）: BOOCH_DOCTOR_MISSING / _OUTDATED / _WARN（0/1）

# 色は lib/color.sh に集約（_BOOCH_COLOR_*）。BOOCH_ROOT 未設定時は本ファイルから推定。
if [ -z "${BOOCH_ROOT:-}" ]; then
  BOOCH_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd) || BOOCH_ROOT=""
fi
if [ -n "${BOOCH_ROOT:-}" ] && [ -f "$BOOCH_ROOT/lib/color.sh" ]; then
  # shellcheck source=/dev/null
  source "$BOOCH_ROOT/lib/color.sh"
else
  # color.sh が無いときも未定義参照で caller の set -u を巻き込まないよう空で定義する。
  _BOOCH_COLOR_RED=''; _BOOCH_COLOR_YELLOW=''; _BOOCH_COLOR_GREEN=''
  _BOOCH_COLOR_CYAN=''; _BOOCH_COLOR_DIM=''; _BOOCH_COLOR_RESET=''
fi

BOOCH_DOCTOR_MISSING=0
BOOCH_DOCTOR_OUTDATED=0
BOOCH_DOCTOR_WARN=0

booch_doctor_init() {
  BOOCH_DOCTOR_MISSING=0
  BOOCH_DOCTOR_OUTDATED=0
  BOOCH_DOCTOR_WARN=0
}

# 比較用にバージョン文字列を正規化する。rust-v / v プレフィックスを外し、先頭空白を除き、
# 最初の空白トークンだけを取り（"1.2.3 (Foo Bar)" → "1.2.3" のようにツール名等の付随語を
# 落とす）、+build メタを除く。
# 例: "rust-v0.20.0" / "v0.20.0" / "0.20.0 " / "2.1.195 (Claude Code)" → "0.20.0" / "2.1.195"。
booch_ver_norm() { # version
  local v=$1
  v=${v#rust-v}
  v=${v#v}
  v=${v#"${v%%[![:space:]]*}"}   # 先頭空白除去
  v=${v%%[[:space:]]*}           # 最初の空白以降（付随語）を捨てる
  v=${v%%+*}                     # +build メタ除去
  printf '%s' "$v"
}

# 1 行を描画し、status に応じて集計を更新する。
booch_doctor_row() { # label status [value] [note]
  local label=$1 status=$2 value=${3:-} note=${4:-}
  case "$status" in
    ok)
      printf '  %-30s %s[OK]%s  %s\n' \
        "$label" "$_BOOCH_COLOR_GREEN" "$_BOOCH_COLOR_RESET" "$value" ;;
    outdated)
      printf '  %-30s %s[OK]%s  %-20s %s(update available: %s)%s\n' \
        "$label" "$_BOOCH_COLOR_GREEN" "$_BOOCH_COLOR_RESET" "$value" \
        "$_BOOCH_COLOR_YELLOW" "$note" "$_BOOCH_COLOR_RESET"
      BOOCH_DOCTOR_OUTDATED=1 ;;
    missing)
      printf '  %-30s %s[MISSING]%s %s\n' \
        "$label" "$_BOOCH_COLOR_RED" "$_BOOCH_COLOR_RESET" "$value"
      BOOCH_DOCTOR_MISSING=1 ;;
    warn)
      printf '  %-30s %s[WARN]%s %s\n' \
        "$label" "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET" "$value"
      BOOCH_DOCTOR_WARN=1 ;;
    skip)
      printf '  %-30s %s[SKIP]%s %s\n' \
        "$label" "$_BOOCH_COLOR_DIM" "$_BOOCH_COLOR_RESET" "$value" ;;
    *)
      # 未知 status（呼び出し側のタイポ等）を黙って通すと、欠落が「all good」に
      # 化ける。診断を stderr に出し、警告として集計に残す。
      printf '  %-30s %s\n' "$label" "$value"
      printf 'booch_doctor_row: 未知の status: %s（%s）\n' "$status" "$label" >&2
      BOOCH_DOCTOR_WARN=1 ;;
  esac
}

# current / latest を比較して適切な行を出す便利関数。
#   current 空        → missing
#   latest 空         → ok（latest 不明）
#   正規化して不一致  → outdated
#   一致              → ok
booch_doctor_tool() { # label current latest
  local label=$1 current=$2 latest=$3
  if [ -z "$current" ]; then
    booch_doctor_row "$label" missing
  elif [ -z "$latest" ]; then
    booch_doctor_row "$label" ok "$current  (latest: unknown)"
  elif [ "$(booch_ver_norm "$current")" != "$(booch_ver_norm "$latest")" ]; then
    booch_doctor_row "$label" outdated "$current" "$latest"
  else
    booch_doctor_row "$label" ok "$current"
  fi
}

# 集計の最終行を出し、終了コードを返す（missing があれば 1、それ以外は 0）。
# outdated / warn は 0 のまま（メッセージのみ。run を促す材料として使う）。
booch_doctor_summary() {
  # 公開変数を非数値で汚されても落ちないよう、数値比較でなく文字列一致で見る。
  if [ "${BOOCH_DOCTOR_MISSING:-0}" = "1" ]; then
    printf '%sSome tools are missing.%s\n' "$_BOOCH_COLOR_RED" "$_BOOCH_COLOR_RESET"
    return 1
  elif [ "${BOOCH_DOCTOR_OUTDATED:-0}" = "1" ]; then
    printf '%sSome tools are outdated.%s\n' "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET"
  elif [ "${BOOCH_DOCTOR_WARN:-0}" = "1" ]; then
    printf '%sTools are up to date, but warnings were found.%s\n' \
      "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET"
  else
    printf 'All tools are up to date.\n'
  fi
}

# --- リモート最新版の並列取得 ---------------------------------------------------
# doctor で多数のリモート版を取得する際、temp ディレクトリへ並列に書き込み、自分が起動した
# PID だけを待つ（bare wait は呼び出し側の他の background ジョブ＝sudo キープアライブ等を
# 巻き込んで hang しうるため）。どの URL を・どう抽出して・どのツールを診るかは利用側が決める。
#
#   booch_doctor_prefetch_init
#   booch_doctor_prefetch go bash -c 'curl -fsSL ... | head -1'
#   booch_doctor_prefetch_wait
#   latest=$(booch_doctor_prefetch_get go)
#   booch_doctor_prefetch_cleanup
# パイプライン等は `bash -c '...'` で 1 コマンドとして渡す。

BOOCH_DOCTOR_PREFETCH_DIR=""
_BOOCH_DOCTOR_PREFETCH_PIDS=()

booch_doctor_prefetch_init() {
  BOOCH_DOCTOR_PREFETCH_DIR=$(mktemp -d) || return 1
  _BOOCH_DOCTOR_PREFETCH_PIDS=()
}

# name で識別する取得を background 起動する（stdout を temp の name へ）。
booch_doctor_prefetch() { # name cmd...
  local name=$1; shift
  "$@" > "$BOOCH_DOCTOR_PREFETCH_DIR/$name" 2>/dev/null &
  _BOOCH_DOCTOR_PREFETCH_PIDS+=("$!")
}

# 起動済みの取得（自分の PID のみ）の完了を待つ。
booch_doctor_prefetch_wait() {
  [ "${#_BOOCH_DOCTOR_PREFETCH_PIDS[@]}" -gt 0 ] \
    && wait "${_BOOCH_DOCTOR_PREFETCH_PIDS[@]}" 2>/dev/null
  return 0
}

# 取得結果（name）を読む（未取得なら空）。
booch_doctor_prefetch_get() { # name
  cat "$BOOCH_DOCTOR_PREFETCH_DIR/$name" 2>/dev/null
}

# temp ディレクトリを片付ける。
booch_doctor_prefetch_cleanup() {
  [ -n "$BOOCH_DOCTOR_PREFETCH_DIR" ] && rm -rf "$BOOCH_DOCTOR_PREFETCH_DIR"
  BOOCH_DOCTOR_PREFETCH_DIR=""
  _BOOCH_DOCTOR_PREFETCH_PIDS=()
}

# apt パッケージの導入状況を 1 行で診断する。candidate が installed より厳密に新しいときだけ
# outdated とする（サードパーティ repo 無効化で candidate がディストリ版へ落ちた場合に
# ダウングレードを更新と誤表示しないよう、文字列比較ではなく dpkg のバージョン比較を使う）。
# どのパッケージを診るかは利用側が決める。
booch_doctor_apt_pkg() { # label command package
  local label=$1 cmd=$2 pkg=$3
  if ! command -v "$cmd" >/dev/null 2>&1; then
    booch_doctor_row "$label" missing
    return
  fi
  local installed candidate
  installed=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "unknown")
  candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2}')
  if [ -n "$candidate" ] && dpkg --compare-versions "$candidate" gt "$installed" 2>/dev/null; then
    booch_doctor_row "$label" outdated "$installed" "$candidate"
  else
    booch_doctor_row "$label" ok "$installed"
  fi
}
