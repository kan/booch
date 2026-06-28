#!/usr/bin/env bash
# OS 情報の検出。os-release を読み、後続処理がバージョンで分岐できるよう
# グローバル変数として公開する。主対象は WSL2 上の Ubuntu だが、非 Ubuntu や
# os-release 不在でも落ちないよう空文字へフォールバックする。
#
#   BOOCH_OS_ID            例: ubuntu
#   BOOCH_OS_VERSION_ID    例: 26.04
#   BOOCH_OS_VERSION_MAJOR 例: 26      （数値比較用。VERSION_ID の major 部分）
#   BOOCH_OS_CODENAME      例: resolute
#
# 使い方:
#   source "$BOOCH_ROOT/lib/os.sh"
#   booch_detect_os                 # /etc/os-release を読む
#   echo "$BOOCH_OS_ID $BOOCH_OS_VERSION_MAJOR"
#
# booch_detect_os は第 1 引数で os-release のパスを差し替えられる（テスト用）。

# BOOCH_OS_* は呼び出し側が参照する公開出力変数（os.sh 内では代入のみ）。
# shellcheck disable=SC2034
BOOCH_OS_ID=""
BOOCH_OS_VERSION_ID=""
BOOCH_OS_VERSION_MAJOR=""
BOOCH_OS_CODENAME=""

booch_detect_os() {
  local file="${1:-/etc/os-release}"

  # 繰り返し呼んでも前回値が残らないよう毎回リセットする。
  BOOCH_OS_ID=""
  BOOCH_OS_VERSION_ID=""
  BOOCH_OS_VERSION_MAJOR=""
  BOOCH_OS_CODENAME=""

  [ -r "$file" ] || return 0

  # サブシェル内で source して必要な値だけ取り出す（呼び出し元の名前空間を汚さない
  # ため。printf %q で空白等を含んでも安全に eval で受け取る）。codename は
  # VERSION_CODENAME を優先し、無ければ UBUNTU_CODENAME にフォールバックする。
  # os-release を parse でなく source するのは簡潔さのため。値の caller への注入は
  # printf %q + eval で無害化するが、ファイル自体のコード実行は許容する（信頼できる
  # システムファイル前提）。ファイルが exit 等でサブシェルを早期終了させても
  # caller を巻き込まないよう、ローカルは空で初期化しておく。
  local id="" vid="" codename=""
  eval "$(
    # shellcheck disable=SC1090  # os-release は実行時に決まるパス（fixture 含む）
    . "$file" 2>/dev/null
    printf 'id=%q vid=%q codename=%q\n' \
      "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  )"
  BOOCH_OS_ID="$id"
  BOOCH_OS_VERSION_ID="$vid"
  BOOCH_OS_CODENAME="$codename"
  BOOCH_OS_VERSION_MAJOR="${vid%%.*}"
}
