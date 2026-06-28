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

# 色は tty かつ NO_COLOR 未設定のときだけ使う（パイプ / CI / ログ捕捉対策）。
# NOTE: runner.sh と同じ gating を重複保持している。将来 lib/color.sh へ集約する。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _BOOCH_DC_RED=$'\033[1;31m'
  _BOOCH_DC_YELLOW=$'\033[1;33m'
  _BOOCH_DC_GREEN=$'\033[1;32m'
  _BOOCH_DC_DIM=$'\033[2m'
  _BOOCH_DC_RESET=$'\033[0m'
else
  _BOOCH_DC_RED=''; _BOOCH_DC_YELLOW=''; _BOOCH_DC_GREEN=''
  _BOOCH_DC_DIM=''; _BOOCH_DC_RESET=''
fi

BOOCH_DOCTOR_MISSING=0
BOOCH_DOCTOR_OUTDATED=0
BOOCH_DOCTOR_WARN=0

booch_doctor_init() {
  BOOCH_DOCTOR_MISSING=0
  BOOCH_DOCTOR_OUTDATED=0
  BOOCH_DOCTOR_WARN=0
}

# 比較用にバージョン文字列を正規化する。rust-v / v プレフィックス、+build メタ、
# 前後空白を除く（例: "rust-v0.20.0" / "v0.20.0" / "0.20.0 " → "0.20.0"）。
booch_ver_norm() { # version
  local v=$1
  v=${v#rust-v}
  v=${v#v}
  v=${v%%+*}
  v=${v#"${v%%[![:space:]]*}"}   # 先頭空白除去
  v=${v%"${v##*[![:space:]]}"}   # 末尾空白除去
  printf '%s' "$v"
}

# 1 行を描画し、status に応じて集計を更新する。
booch_doctor_row() { # label status [value] [note]
  local label=$1 status=$2 value=${3:-} note=${4:-}
  case "$status" in
    ok)
      printf '  %-30s %s[OK]%s  %s\n' \
        "$label" "$_BOOCH_DC_GREEN" "$_BOOCH_DC_RESET" "$value" ;;
    outdated)
      printf '  %-30s %s[OK]%s  %-20s %s(update available: %s)%s\n' \
        "$label" "$_BOOCH_DC_GREEN" "$_BOOCH_DC_RESET" "$value" \
        "$_BOOCH_DC_YELLOW" "$note" "$_BOOCH_DC_RESET"
      BOOCH_DOCTOR_OUTDATED=1 ;;
    missing)
      printf '  %-30s %s[MISSING]%s %s\n' \
        "$label" "$_BOOCH_DC_RED" "$_BOOCH_DC_RESET" "$value"
      BOOCH_DOCTOR_MISSING=1 ;;
    warn)
      printf '  %-30s %s[WARN]%s %s\n' \
        "$label" "$_BOOCH_DC_YELLOW" "$_BOOCH_DC_RESET" "$value"
      BOOCH_DOCTOR_WARN=1 ;;
    skip)
      printf '  %-30s %s[SKIP]%s %s\n' \
        "$label" "$_BOOCH_DC_DIM" "$_BOOCH_DC_RESET" "$value" ;;
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
    printf '%sSome tools are missing.%s\n' "$_BOOCH_DC_RED" "$_BOOCH_DC_RESET"
    return 1
  elif [ "${BOOCH_DOCTOR_OUTDATED:-0}" = "1" ]; then
    printf '%sSome tools are outdated.%s\n' "$_BOOCH_DC_YELLOW" "$_BOOCH_DC_RESET"
  elif [ "${BOOCH_DOCTOR_WARN:-0}" = "1" ]; then
    printf '%sTools are up to date, but warnings were found.%s\n' \
      "$_BOOCH_DC_YELLOW" "$_BOOCH_DC_RESET"
  else
    printf 'All tools are up to date.\n'
  fi
}
