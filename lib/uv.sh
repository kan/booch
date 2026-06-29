#!/usr/bin/env bash
# uv（Python ツールチェイン管理）ヘルパー。uv 本体の導入/自己更新と、uv tool の
# 冪等な導入/更新を共通化する。ansible-core のような「system python を避けて uv 管理の
# Python 上に隔離したいツール」を入れる土台。
#
# 個人/移行固有のもの（pipx からの移行・特定ツール名・python バージョンの選択）は
# 持ち込まない。利用側が booch_uv_tool_ensure に渡す / 事前に pipx を撤去する。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/uv.sh"
#   booch_uv_ensure
#   booch_uv_tool_ensure ansible-core 3.12      # 未導入なら python 3.12 で導入、あれば upgrade
#
# 依存: curl（bootstrap 用）, uv（導入後）。
#
# テスト用の継ぎ目（seam）。次を上書きすると network 無しで純粋ロジックを検証できる:
#   booch_uv_present              uv が PATH にあるか
#   booch_uv_self_update          uv self update
#   booch_uv_bootstrap_install    astral のスクリプトで uv を導入
#   booch_uv_tool_list            uv tool list の出力
#   booch_uv_tool_install <args>  uv tool install <args>
#   booch_uv_tool_upgrade <tool>  uv tool upgrade <tool>

booch_uv_present() { command -v uv >/dev/null 2>&1; }

booch_uv_installed_version() {
  booch_uv_present || return 0
  uv --version 2>/dev/null | awk '{print $2}'
}

booch_uv_self_update() { uv self update >/dev/null 2>&1; }
# install スクリプトを temp に落としてから実行する（`curl | sh` だと curl 失敗が
# sh の成功で隠れるため。apt.sh / github.sh と同じ方針）。
booch_uv_bootstrap_install() {
  local tmp; tmp=$(mktemp)
  # 発火時に自身を解除し、RETURN トラップが呼び出し元へ漏れて再発火するのを防ぐ
  # （呼び出し元の set -u 下で解放済みローカル変数を踏んで落ちないように）。
  trap 'rm -f "${tmp:-}"; trap - RETURN' RETURN
  curl -LsSf https://astral.sh/uv/install.sh -o "$tmp" || return 1
  sh "$tmp" >/dev/null 2>&1 || return 1
}
booch_uv_tool_list() { uv tool list 2>/dev/null; }
booch_uv_tool_install() { uv tool install "$@" >/dev/null 2>&1; }
booch_uv_tool_upgrade() { uv tool upgrade "$@" >/dev/null 2>&1; }

# uv 本体を用意する。あれば self-update（失敗は致命でない＝uv は既にある）、無ければ
# 導入する。導入後は ~/.local/bin（astral の既定）を PATH に通し、実際に uv が呼べる
# ことまで確認してから成功とする（通さないと直後の uv 呼び出しが command not found）。
booch_uv_ensure() {
  if booch_uv_present; then
    booch_uv_self_update || true
    return 0
  fi
  booch_uv_bootstrap_install || return 1
  export PATH="$HOME/.local/bin:$PATH"
  booch_uv_present || { echo "uv: 導入後も見つかりません（PATH を確認）" >&2; return 1; }
}

# uv tool 一覧に <tool> が（厳密な名前一致で）あるか。前方一致の誤検出を避けるため
# awk で第 1 フィールドの完全一致を見る（"ansible" が "ansible-core" を拾わない）。
booch_uv_tool_installed() { # tool
  booch_uv_tool_list | awk -v t="$1" '$1==t{found=1} END{exit !found}'
}

# uv tool を冪等に用意する。導入済みなら upgrade、未導入なら install。python 指定可。
# 第 3 引数に "force" を渡すと install 時に --force を付ける（pipx 等で入れた他管理の
# 実行ファイルが ~/.local/bin に残っていると uv tool install が "Executables already
# exist" で失敗するため、移行用途で上書き導入したいとき）。
booch_uv_tool_ensure() { # tool [python] [force]
  local tool=$1 py=${2:-} force=${3:-}
  if booch_uv_tool_installed "$tool"; then
    booch_uv_tool_upgrade "$tool"
    return
  fi
  local args=()
  [ "$force" = force ] && args+=(--force)
  [ -n "$py" ] && args+=(--python "$py")
  booch_uv_tool_install "${args[@]}" "$tool"
}
