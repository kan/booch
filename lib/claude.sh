#!/usr/bin/env bash
# Claude Code ヘルパー。本体の導入/更新と、marketplace / plugin の冪等な追加・更新を
# 共通化する。どの marketplace・どの plugin を入れるか（個人の選択）や、WSL + 1Password
# 環境での SSH→HTTPS 迂回（GIT_CONFIG_* の設定）は持ち込まない。利用側が選択して呼ぶ。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/claude.sh"
#   booch_claude_install
#   booch_claude_marketplace_ensure <owner>/<marketplace>
#   booch_claude_marketplace_update_all
#   booch_claude_plugin_ensure <plugin>@<marketplace>   # outcome を stdout に 1 行返す
#
# booch_claude_plugin_ensure は導入結果を stdout にタブ区切り 1 行
# "<status>\t<old>\t<new>"（status= installed|updated|current）で返す。利用側（ジョブ）は
# これを受けて booch_result を書ける（役割分担: ヘルパー=動作、ジョブ=報告）。例:
#   IFS=$'\t' read -r status old new < <(booch_claude_plugin_ensure acme-tools@acme)
#   booch_result "  acme-tools" "$status" "$old" "$new"
#
# PATH 上の claude は WSL 経由で Windows 版を拾うことがあるため、install.sh が置く
# Linux 版（既定 ~/.local/bin/claude）に固定する。BOOCH_CLAUDE_BIN で上書き可能。
#
# 依存: curl, Claude Code（導入後）。
#
# テスト用の継ぎ目（seam）:
#   booch_claude_run <args...>     固定した claude バイナリを実行（read/write 共通）
#   booch_claude_install_script    本体インストーラ（install.sh）の実行

# runner の bash -c 子（ジョブ）から参照できるよう export する。非 export だと
# ジョブ内で空になり、install/marketplace/plugin 操作がすべて空パスで壊れる。
: "${BOOCH_CLAUDE_BIN:=$HOME/.local/bin/claude}"
export BOOCH_CLAUDE_BIN

booch_claude_run() { "$BOOCH_CLAUDE_BIN" "$@"; }

# install.sh を temp に落としてから実行する（`curl | bash` だと curl 失敗が bash の
# 成功で隠れるため。apt.sh / github.sh / uv.sh と同じ方針）。
booch_claude_install_script() {
  local tmp; tmp=$(mktemp)
  # 発火時に自身を解除し、RETURN トラップが呼び出し元へ漏れて再発火するのを防ぐ
  # （呼び出し元の set -u 下で解放済みローカル変数を踏んで落ちないように）。
  trap 'rm -f "${tmp:-}"; trap - RETURN' RETURN
  curl -fsSL https://claude.ai/install.sh -o "$tmp" || return 1
  bash "$tmp" || return 1
}

booch_claude_installed_version() {
  [ -x "$BOOCH_CLAUDE_BIN" ] || return 0
  # head -1 だと pipefail 下で SIGPIPE(141) になりうるので、awk で全消費して 1 行目を出す。
  booch_claude_run --version 2>/dev/null | awk 'NR==1{print}'
}

# 本体を導入/更新する（PATH の Windows 版でなく固定バイナリに対して行う）。
# 既存なら自己更新、失敗時はインストーラで入れ直す。未導入ならインストーラで導入。
# 最後に固定パスで実行可能になっていることまで確認する（uv.sh と同方針）。
booch_claude_install() {
  if [ ! -x "$BOOCH_CLAUDE_BIN" ]; then
    booch_claude_install_script || return 1
  else
    booch_claude_run update >/dev/null 2>&1 || booch_claude_install_script || return 1
  fi
  [ -x "$BOOCH_CLAUDE_BIN" ] || {
    echo "claude: 導入後も見つかりません: $BOOCH_CLAUDE_BIN" >&2
    return 1
  }
}

# marketplace を冪等に追加する。list の "Source: GitHub (owner/repo)" に source が
# 出るので、"(owner/repo)" を括弧ごと固定文字列照合して未登録なら add する
# （括弧を含めることで foo/bar が (foo/bar-baz) を誤検出しない）。
booch_claude_marketplace_ensure() { # source (owner/repo)
  local src=$1
  if booch_claude_run plugin marketplace list 2>/dev/null | grep -qF "($src)"; then
    return 0
  fi
  booch_claude_run plugin marketplace add "$src"
}

# 全 marketplace を最新化する（plugin 更新の前に呼ぶ）。
booch_claude_marketplace_update_all() {
  booch_claude_run plugin marketplace update >/dev/null 2>&1
}

# plugin が導入済みか。list の "❯ <plugin@source>" 行の id を完全一致で判定する
# （非アンカー部分一致だと @foo が @foo2 を誤検出するため awk で第 2 フィールド一致）。
booch_claude_plugin_installed() { # plugin@source
  booch_claude_run plugin list 2>/dev/null \
    | awk -v p="$1" '$1=="❯" && $2==p {found=1} END{exit !found}'
}

# plugin の導入バージョン。"❯" 行で対象ブロックかを判定（別ブロックに入ったら解除）し、
# 対象ブロック内の最初の "Version:" 行の値を返す（Version 行が無いブロックで次の版を拾わない）。
booch_claude_plugin_version() { # plugin@source
  booch_claude_run plugin list 2>/dev/null | awk -v p="$1" '
    $1=="❯" { found = ($2==p) }
    found && $1=="Version:" { print $2; exit }
  '
}

# plugin を冪等に用意する。導入済みなら update（失敗は致命でない）、未導入なら install。
# 導入結果を stdout にタブ区切り 1 行 "<status>\t<old>\t<new>"
# （status= installed|updated|current）で返し、呼び出し側が booch_result を書けるようにする。
# install 失敗は従来どおり非 0 を返す（出力は出さない）。update 失敗は許容し、版が変わら
# なければ current として報告する。
booch_claude_plugin_ensure() { # plugin@source -> "<status>\t<old>\t<new>"
  local plugin=$1 old new status
  if booch_claude_plugin_installed "$plugin"; then
    old=$(booch_claude_plugin_version "$plugin")
    booch_claude_run plugin update "$plugin" >/dev/null 2>&1 || true
    new=$(booch_claude_plugin_version "$plugin")
    if [ "$old" = "$new" ]; then status=current; else status=updated; fi
  else
    old=""
    booch_claude_run plugin install "$plugin" || return 1
    new=$(booch_claude_plugin_version "$plugin")
    status=installed
  fi
  printf '%s\t%s\t%s\n' "$status" "$old" "$new"
}

# --- 列挙・削除・MCP 登録のプリミティブ（autoremove / MCP 再登録で使う）---------------
# plugin list / marketplace list は先頭に "❯" マーカー付きで name が 2 列目に出る。その name
# だけを 1 行ずつ返す共通パーサ（"❯" は UTF-8 の e2 9d af）。CLI 出力書式に依存する薄い層で、
# 利用側の autoremove / 診断がこの 1 箇所を共有する（各所で同じ awk を書かない）。
_booch_claude_marked_names() { # claude-subcommand...
  booch_claude_run "$@" 2>/dev/null | awk '$1=="\xe2\x9d\xaf"{print $2}'
}

# 導入済みプラグイン名（plugin@source）を 1 行ずつ返す。
booch_claude_plugin_list() {
  _booch_claude_marked_names plugin list
}

# プラグインをアンインストールする（成功で 0）。
booch_claude_plugin_uninstall() { # plugin@source
  booch_claude_run plugin uninstall "$1" >/dev/null 2>&1
}

# 登録済み marketplace 名を 1 行ずつ返す。
booch_claude_marketplace_list() {
  _booch_claude_marked_names plugin marketplace list
}

# marketplace を登録解除する（clone ディレクトリも消える。成功で 0）。
booch_claude_marketplace_remove() { # name
  booch_claude_run plugin marketplace remove "$1" >/dev/null 2>&1
}

# user スコープ MCP を冪等登録する（remove → add で定義変更に追従）。対話用シェル関数ラッパー
# （1Password 未到達で本体を起動しない等）を迂回するため booch_claude_run（固定バイナリ直叩き）
# で行う。プロビジョニングを実行時トークンに依存させないための設計。
#   引数: <name> <claude mcp add に渡す残りの引数...>（-e KEY=val / -- cmd args 等）。成功で 0。
booch_claude_mcp_ensure() { # name mcp-add-args...
  local name=$1; shift
  # remove は未登録サーバーに exit 1 を返す。set -e 下の呼び出しでも初回登録（未存在→add）が
  # 中断しないよう握る。
  booch_claude_run mcp remove -s user "$name" >/dev/null 2>&1 || true
  booch_claude_run mcp add -s user "$name" "$@" >/dev/null 2>&1
}

# user スコープ MCP 名を 1 行ずつ返す（既定 ~/.claude.json の mcpServers キー）。jq 必須で、
# jq / ファイルが無ければ無出力（呼び出し側は空を「対象なし」として扱える）。
booch_claude_mcp_list() { # [claude_json]
  local cj=${1:-$HOME/.claude.json}
  [ -f "$cj" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.mcpServers // {} | keys[]' "$cj" 2>/dev/null
}

# user スコープ MCP を登録解除する（成功で 0）。
booch_claude_mcp_remove() { # name
  booch_claude_run mcp remove -s user "$1" >/dev/null 2>&1
}

# autoremove plan の Claude 系 kind（plugin / marketplace / mcpserver）を削除する。パス検証が
# 要る利用側固有の kind（marketplace clone 残渣 / 壊れ symlink 等）は扱わず、2 を返して呼び出し側へ
# 委ねる（安全な削除の責任分界。0=削除実行 / 1=削除失敗 / 2=非対象 kind）。
booch_claude_autoremove_apply() { # kind id
  case "$1" in
    plugin)      booch_claude_plugin_uninstall "$2" ;;
    marketplace) booch_claude_marketplace_remove "$2" ;;
    mcpserver)   booch_claude_mcp_remove "$2" ;;
    *) return 2 ;;
  esac
}
