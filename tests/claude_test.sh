#!/usr/bin/env bash
# lib/claude.sh のユニットテスト。claude 実行（booch_claude_run）を canned 出力/捕捉に
# 差し替え、install/marketplace/plugin の冪等ロジックを検証する（実 claude 不要）。

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
  local rc; if booch_claude_plugin_ensure acme-tools@acme; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

run_tests
