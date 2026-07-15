#!/usr/bin/env bash
# lib/claude.sh のユニットテスト。claude 実行（booch_claude_run）を canned 出力/捕捉に
# 差し替え、install/marketplace/plugin の冪等ロジックを検証する（実 claude 不要）。

# stub（booch_claude_run 等の再定義）は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317,SC2329

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/claude.sh
source "$BOOCH_ROOT/lib/claude.sh"

# --- 本体 install ---
test_claude_install_runs_script_when_absent() {
  local d; d=$(mktemp -d); BOOCH_CLAUDE_BIN="$d/claude"
  local script_called=0
  # 導入後検証を通すため、インストーラ stub は実際にバイナリを作る。
  booch_claude_install_script() { script_called=1; printf '#!/bin/sh\n' > "$BOOCH_CLAUDE_BIN"; chmod +x "$BOOCH_CLAUDE_BIN"; }
  booch_claude_install
  rm -rf "$d"
  assert_eq "1" "$script_called" "未導入ならインストーラ実行"
}
# インストーラが成功扱いでもバイナリが無ければ install は失敗（導入後検証の回帰ガード）。
test_claude_install_fails_if_missing_after_script() {
  BOOCH_CLAUDE_BIN="/nonexistent/claude"
  booch_claude_install_script() { :; }   # "成功" だが何も作らない
  local rc; if booch_claude_install 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
test_claude_install_updates_when_present() {
  local d; d=$(mktemp -d); BOOCH_CLAUDE_BIN="$d/claude"
  printf '#!/bin/sh\n' > "$BOOCH_CLAUDE_BIN"; chmod +x "$BOOCH_CLAUDE_BIN"
  local script_called=0 update_cap=""
  booch_claude_install_script() { script_called=1; }
  booch_claude_run() { update_cap="$*"; return 0; }
  booch_claude_install
  rm -rf "$d"
  assert_eq "0" "$script_called" "導入済みならインストーラを呼ばない"
  assert_eq "update" "$update_cap"
}
test_claude_install_falls_back_when_update_fails() {
  local d; d=$(mktemp -d); BOOCH_CLAUDE_BIN="$d/claude"
  printf '#!/bin/sh\n' > "$BOOCH_CLAUDE_BIN"; chmod +x "$BOOCH_CLAUDE_BIN"
  local script_called=0
  booch_claude_install_script() { script_called=1; }
  booch_claude_run() { return 1; }   # update 失敗
  booch_claude_install
  rm -rf "$d"
  assert_eq "1" "$script_called" "update 失敗ならインストーラで入れ直す"
}

# --- installed_version ---
test_claude_installed_version() {
  local d; d=$(mktemp -d); BOOCH_CLAUDE_BIN="$d/claude"
  printf '#!/bin/sh\necho "2.1.195 (Claude Code)"\n' > "$BOOCH_CLAUDE_BIN"; chmod +x "$BOOCH_CLAUDE_BIN"
  assert_eq "2.1.195 (Claude Code)" "$(booch_claude_installed_version)"
  rm -rf "$d"
}
test_claude_installed_version_empty_when_absent() {
  BOOCH_CLAUDE_BIN="/nonexistent/claude"
  assert_eq "" "$(booch_claude_installed_version)"
}
# runner の bash -c 子（ジョブ）に伝わるよう BOOCH_CLAUDE_BIN は export されている。
test_claude_bin_is_exported() {
  assert_eq "$BOOCH_CLAUDE_BIN" "$(bash -c 'printf %s "${BOOCH_CLAUDE_BIN:-UNSET}"')"
}

# --- marketplace ---
test_claude_marketplace_ensure_skips_when_present() {
  local cap=""
  booch_claude_run() {
    case "$*" in
      "plugin marketplace list") printf '  ❯ acme\n    Source: GitHub (acme/claude-plugin)\n' ;;
      *) cap="$*" ;;
    esac
  }
  booch_claude_marketplace_ensure acme/claude-plugin
  assert_eq "" "$cap" "登録済みなら add しない"
}
test_claude_marketplace_ensure_adds_when_absent() {
  local cap=""
  booch_claude_run() {
    case "$*" in
      "plugin marketplace list") printf '  ❯ other\n    Source: GitHub (foo/bar)\n' ;;
      *) cap="$*" ;;
    esac
  }
  booch_claude_marketplace_ensure acme/claude-plugin
  assert_eq "plugin marketplace add acme/claude-plugin" "$cap"
}
# 部分一致の誤検出ガード: foo/bar は (foo/bar-baz) にマッチせず add する。
test_claude_marketplace_ensure_adds_when_only_substring_present() {
  local cap=""
  booch_claude_run() {
    case "$*" in
      "plugin marketplace list") printf '  ❯ baz\n    Source: GitHub (foo/bar-baz)\n' ;;
      *) cap="$*" ;;
    esac
  }
  booch_claude_marketplace_ensure foo/bar
  assert_eq "plugin marketplace add foo/bar" "$cap"
}
test_claude_marketplace_update_all_invokes_update() {
  local cap=""
  booch_claude_run() { cap="$*"; }
  booch_claude_marketplace_update_all
  assert_eq "plugin marketplace update" "$cap"
}

# --- plugin 判定 / バージョン ---
test_claude_plugin_installed_true() {
  booch_claude_run() { case "$*" in "plugin list") printf '  ❯ acme-tools@acme\n    Version: 1.72.0\n' ;; esac; }
  local rc; if booch_claude_plugin_installed acme-tools@acme; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}
test_claude_plugin_installed_false() {
  booch_claude_run() { case "$*" in "plugin list") printf '  ❯ other@x\n    Version: 1.0.0\n' ;; esac; }
  local rc; if booch_claude_plugin_installed acme-tools@acme; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
# 別 marketplace の同名 plugin（@acme2）を @acme と誤検出しない（id 完全一致）。
test_claude_plugin_installed_no_cross_marketplace_match() {
  booch_claude_run() { case "$*" in "plugin list") printf '  ❯ acme-tools@acme2\n    Version: 9.9.9\n' ;; esac; }
  local rc; if booch_claude_plugin_installed acme-tools@acme; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
test_claude_plugin_version_reads_following_version_line() {
  booch_claude_run() {
    case "$*" in
      "plugin list") printf '  ❯ acme-tools@acme\n    Version: 1.72.0\n  ❯ codex@openai-codex\n    Version: 1.0.5\n' ;;
    esac
  }
  assert_eq "1.72.0" "$(booch_claude_plugin_version acme-tools@acme)"
  assert_eq "1.0.5"  "$(booch_claude_plugin_version codex@openai-codex)"
}
# 対象ブロックに Version 行が無ければ、次ブロックの版を拾わず空を返す。
test_claude_plugin_version_empty_when_no_version_line() {
  booch_claude_run() {
    case "$*" in
      "plugin list") printf '  ❯ broken@x\n    Status: error\n  ❯ other@y\n    Version: 9.9.9\n' ;;
    esac
  }
  assert_eq "" "$(booch_claude_plugin_version broken@x)"
}

# --- plugin_ensure ---
test_claude_plugin_ensure_installs_when_absent() {
  local cap=""
  booch_claude_run() { case "$*" in "plugin list") printf '  ❯ other@x\n' ;; *) cap="$*" ;; esac; }
  booch_claude_plugin_ensure acme-tools@acme
  assert_eq "plugin install acme-tools@acme" "$cap"
}
test_claude_plugin_ensure_updates_when_present() {
  local cap=""
  booch_claude_run() { case "$*" in "plugin list") printf '  ❯ acme-tools@acme\n' ;; *) cap="$*" ;; esac; }
  booch_claude_plugin_ensure acme-tools@acme
  assert_eq "plugin update acme-tools@acme" "$cap"
}
# 導入済み plugin の update が失敗しても ensure は成功（|| true の許容）。
test_claude_plugin_ensure_tolerates_update_failure() {
  booch_claude_run() {
    case "$*" in
      "plugin list") printf '  ❯ acme-tools@acme\n' ;;
      *) return 1 ;;   # update 失敗
    esac
  }
  local rc; if booch_claude_plugin_ensure acme-tools@acme >/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

# --- plugin_ensure の outcome 出力（呼び出し側が booch_result を書けるよう stdout で返す） ---
# 版判定の booch_claude_run は pipeline 経由（サブシェル）で呼ばれカウンタが持てないため、
# install/update の前後状態は temp ファイルで表現する（list はその時点の状態を反映する）。
# 未導入なら install 後に "installed\t\t<new>" を返す。
test_claude_plugin_ensure_outputs_installed() {
  local sf; sf=$(mktemp); : > "$sf"   # 空 = 未導入
  booch_claude_run() {
    case "$*" in
      "plugin list")
        if [ -s "$sf" ]; then printf '  ❯ acme-tools@acme\n    Version: %s\n' "$(cat "$sf")"
        else printf '  ❯ other@x\n'; fi ;;
      "plugin install acme-tools@acme") printf '2.0.0' > "$sf" ;;
    esac
  }
  local out; out=$(booch_claude_plugin_ensure acme-tools@acme)
  rm -f "$sf"
  assert_eq "$(printf 'installed\t\t2.0.0')" "$out"
}

# 導入済みで版が変われば "updated\t<old>\t<new>"（update が状態ファイルの版を上げる）。
test_claude_plugin_ensure_outputs_updated() {
  local sf; sf=$(mktemp); printf '1.0.0' > "$sf"
  booch_claude_run() {
    case "$*" in
      "plugin list") printf '  ❯ acme-tools@acme\n    Version: %s\n' "$(cat "$sf")" ;;
      "plugin update acme-tools@acme") printf '1.1.0' > "$sf" ;;
      *) : ;;
    esac
  }
  local out; out=$(booch_claude_plugin_ensure acme-tools@acme)
  rm -f "$sf"
  assert_eq "$(printf 'updated\t1.0.0\t1.1.0')" "$out"
}

# 導入済みで版が変わらなければ "current\t<v>\t<v>"。
test_claude_plugin_ensure_outputs_current_when_unchanged() {
  booch_claude_run() {
    case "$*" in
      "plugin list") printf '  ❯ acme-tools@acme\n    Version: 3.0.0\n' ;;
      *) : ;;
    esac
  }
  assert_eq "$(printf 'current\t3.0.0\t3.0.0')" "$(booch_claude_plugin_ensure acme-tools@acme)"
}

# install 失敗は非 0 を返し、outcome 行は出さない（従来の失敗伝播を保つ）。
test_claude_plugin_ensure_install_failure_returns_error_without_output() {
  booch_claude_run() {
    case "$*" in
      "plugin list") printf '  ❯ other@x\n' ;;   # 未導入
      *) return 1 ;;                              # install 失敗
    esac
  }
  local out rc
  if out=$(booch_claude_plugin_ensure acme-tools@acme 2>/dev/null); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "" "$out" "失敗時は outcome を出さない"
}

# --- 列挙・削除・MCP プリミティブ（autoremove / 再登録で使う）---
test_claude_plugin_list_returns_names() {
  booch_claude_run() { case "$*" in "plugin list") printf '  ❯ acme-tools@acme\n    Version: 1.0.0\n  ❯ codex@openai-codex\n    Version: 2.0.0\n' ;; esac; }
  assert_eq 'acme-tools@acme
codex@openai-codex' "$(booch_claude_plugin_list)"
}
test_claude_marketplace_list_returns_names() {
  booch_claude_run() { case "$*" in "plugin marketplace list") printf '  ❯ acme\n  ❯ openai-codex\n' ;; esac; }
  assert_eq 'acme
openai-codex' "$(booch_claude_marketplace_list)"
}
test_claude_plugin_uninstall_invokes_command() {
  local cap=""
  booch_claude_run() { cap="$*"; }
  booch_claude_plugin_uninstall acme-tools@acme
  assert_eq "plugin uninstall acme-tools@acme" "$cap"
}
test_claude_marketplace_remove_invokes_command() {
  local cap=""
  booch_claude_run() { cap="$*"; }
  booch_claude_marketplace_remove acme
  assert_eq "plugin marketplace remove acme" "$cap"
}
test_claude_mcp_remove_invokes_user_scope() {
  local cap=""
  booch_claude_run() { cap="$*"; }
  booch_claude_mcp_remove notion
  assert_eq "mcp remove -s user notion" "$cap"
}
# ensure は remove → add の順で呼ぶ（定義変更に追従）。remove の失敗は握って add に到達する。
test_claude_mcp_ensure_removes_then_adds() {
  local calls=""
  booch_claude_run() { calls="$calls|$*"; case "$1 $2" in "mcp remove") return 1 ;; esac; }  # remove は未登録想定で失敗
  local rc; if booch_claude_mcp_ensure notion -e 'K=v' -- npx foo; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_eq "|mcp remove -s user notion|mcp add -s user notion -e K=v -- npx foo" "$calls"
}
# mcp_list は ~/.claude.json の mcpServers キーを返す（jq がある時のみ実質検証）。
test_claude_mcp_list_reads_json() {
  if ! command -v jq >/dev/null 2>&1; then return 0; fi
  local f; f=$(mktemp)
  printf '{"mcpServers":{"notion":{},"playwright":{}}}' > "$f"
  assert_eq 'notion
playwright' "$(booch_claude_mcp_list "$f")"
  rm -f "$f"
}
test_claude_mcp_list_missing_file_empty() {
  assert_eq "" "$(booch_claude_mcp_list /nonexistent/claude.json)"
}
# autoremove_apply は kind を claude プリミティブへ振り分け、非対象 kind は 2 を返す。
test_claude_autoremove_apply_dispatches() {
  local cap=""
  booch_claude_run() { cap="$*"; }
  booch_claude_autoremove_apply plugin acme-tools@acme
  assert_eq "plugin uninstall acme-tools@acme" "$cap"
  booch_claude_autoremove_apply marketplace acme
  assert_eq "plugin marketplace remove acme" "$cap"
  booch_claude_autoremove_apply mcpserver notion
  assert_eq "mcp remove -s user notion" "$cap"
}
test_claude_autoremove_apply_unknown_kind_returns_2() {
  booch_claude_run() { :; }
  local rc; if booch_claude_autoremove_apply mktclone /some/path; then rc=0; else rc=$?; fi
  assert_status 2 "$rc"
}

run_tests
