#!/usr/bin/env bash
# Claude Code ヘルパー。本体の導入/更新と、marketplace / plugin の冪等な追加・更新を
# 共通化する。どの marketplace・どの plugin を入れるか（個人の選択）や、WSL + 1Password
# 環境での SSH→HTTPS 迂回（GIT_CONFIG_* の設定）は持ち込まない。利用側が選択して呼ぶ。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/claude.sh"
#   booch_claude_install
#   booch_claude_marketplace_ensure comlinks/claude-plugin
#   booch_claude_marketplace_update_all
#   booch_claude_plugin_ensure comlinks-tools@comlinks
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
  trap 'rm -f "$tmp"' RETURN
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
# （非アンカー部分一致だと @comlinks が @comlinks2 を誤検出するため awk で第 2 フィールド一致）。
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
booch_claude_plugin_ensure() { # plugin@source
  local plugin=$1
  if booch_claude_plugin_installed "$plugin"; then
    booch_claude_run plugin update "$plugin" >/dev/null 2>&1 || true
  else
    booch_claude_run plugin install "$plugin"
  fi
}
