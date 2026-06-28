#!/usr/bin/env bash
# vendor 更新スクリプト（メンテナンス用。bootstrap / runner からは呼ばれない）。
#
# booch は依存（現状 bash-concurrent のみ）を単純な vendor 方式で取り込み、実体を
# リポジトリにコミットする。本スクリプトはピン留めした版を取得し sha256 で検証して
# vendor/ 配下を更新する。版を上げるときは下の PIN / SHA256 を書き換えて実行し、
# 差分をコミットする。
set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# --- bash-concurrent (https://github.com/themattrix/bash-concurrent, MIT) ---
BC_VERSION="2.4.0"
BC_PIN="fc265c72219193bc5db810a70692bcf0896ed1f3"   # tag 2.4.0
BC_SHA256="146381fe28f80612f9f4822a93ade0bf89d58a774b87172360c2931443111e3d"
BC_DIR="$VENDOR_DIR/bash-concurrent"

_sha256() { sha256sum "$1" | awk '{print $1}'; }

update_bash_concurrent() {
  local base="https://raw.githubusercontent.com/themattrix/bash-concurrent/${BC_PIN}"
  mkdir -p "$BC_DIR"

  # 中断や curl 失敗（set -e で即 abort）で .tmp を残さない。検証前に既存ファイルを
  # 壊さないよう、両方 .tmp に取得 → lib を検証 → まとめて mv（アトミックに差し替え）。
  local lib_tmp="$BC_DIR/concurrent.lib.sh.tmp"
  local lic_tmp="$BC_DIR/LICENSE.tmp"
  trap 'rm -f "$lib_tmp" "$lic_tmp"' RETURN

  echo "fetching bash-concurrent ${BC_VERSION} (${BC_PIN:0:7})..."
  curl -fsSL "${base}/concurrent.lib.sh" -o "$lib_tmp"
  curl -fsSL "${base}/LICENSE" -o "$lic_tmp"

  local got; got=$(_sha256 "$lib_tmp")
  if [ "$got" != "$BC_SHA256" ]; then
    echo "ERROR: checksum mismatch" >&2
    echo "  expected: $BC_SHA256" >&2
    echo "  got:      $got" >&2
    echo "  (版を上げたなら本スクリプト先頭の BC_SHA256 も更新すること)" >&2
    return 1
  fi

  mv "$lib_tmp" "$BC_DIR/concurrent.lib.sh"
  mv "$lic_tmp" "$BC_DIR/LICENSE"
  echo "updated: $BC_DIR/concurrent.lib.sh (sha256 ok)"
}

update_bash_concurrent
