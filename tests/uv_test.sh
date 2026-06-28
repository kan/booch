#!/usr/bin/env bash
# lib/uv.sh のユニットテスト。seam をスタブで差し替え、ensure / tool_installed /
# tool_ensure の分岐を network 無しで検証する。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/uv.sh
source "$BOOCH_ROOT/lib/uv.sh"

# --- booch_uv_ensure ---
test_uv_ensure_self_updates_when_present() {
  booch_uv_present() { return 0; }
  local updated=0 bootstrapped=0
  booch_uv_self_update() { updated=1; }
  booch_uv_bootstrap_install() { bootstrapped=1; }
  booch_uv_ensure
  assert_eq "1" "$updated" "present なら self-update"
  assert_eq "0" "$bootstrapped" "present なら bootstrap しない"
}

# self-update 失敗でも ensure は成功（uv は既にあるため）。
test_uv_ensure_tolerates_self_update_failure() {
  booch_uv_present() { return 0; }
  booch_uv_self_update() { return 1; }
  booch_uv_bootstrap_install() { :; }
  local rc; if booch_uv_ensure; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

test_uv_ensure_bootstraps_when_absent() {
  # 初回 present は absent（bootstrap 誘発）、bootstrap 後の検証では present にする。
  local _pc=0
  booch_uv_present() { if [ "$_pc" -eq 0 ]; then _pc=1; return 1; else return 0; fi; }
  local updated=0 bootstrapped=0
  booch_uv_self_update() { updated=1; }
  booch_uv_bootstrap_install() { bootstrapped=1; }
  booch_uv_ensure
  assert_eq "1" "$bootstrapped" "absent なら bootstrap"
  assert_eq "0" "$updated" "absent なら self-update しない"
}

test_uv_ensure_propagates_bootstrap_failure() {
  booch_uv_present() { return 1; }
  booch_uv_bootstrap_install() { return 1; }
  local rc; if booch_uv_ensure; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# bootstrap が成功扱いでも uv が見つからなければ ensure は失敗（導入後検証の回帰ガード）。
test_uv_ensure_fails_if_uv_missing_after_bootstrap() {
  booch_uv_present() { return 1; }      # 検証でも見つからない
  booch_uv_bootstrap_install() { :; }   # "成功"
  local rc; if booch_uv_ensure 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- booch_uv_tool_installed（厳密な名前一致） ---
test_uv_tool_installed_true_when_listed() {
  booch_uv_tool_list() { printf 'ansible-core v2.16.3\n- ansible\n'; }
  local rc; if booch_uv_tool_installed ansible-core; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}
test_uv_tool_installed_false_when_absent() {
  booch_uv_tool_list() { printf 'ruff 0.5.0\n'; }
  local rc; if booch_uv_tool_installed ansible-core; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
# 前方一致では拾わない（"ansible" は "ansible-core" にマッチしない）。
test_uv_tool_installed_exact_match_only() {
  booch_uv_tool_list() { printf 'ansible-core v2.16.3\n'; }
  local rc; if booch_uv_tool_installed ansible; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
# 実行ファイル行（"- ansible"）は $1 が "-" なので拾わない（$1 完全一致の回帰ガード）。
test_uv_tool_installed_ignores_executable_lines() {
  booch_uv_tool_list() { printf 'foo v1.0\n- ansible\n'; }
  local rc; if booch_uv_tool_installed ansible; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- booch_uv_tool_ensure ---
test_uv_tool_ensure_upgrades_when_present() {
  booch_uv_tool_installed() { return 0; }
  local up_args="__unset__" inst_called=0
  booch_uv_tool_upgrade() { up_args="$*"; }
  booch_uv_tool_install() { inst_called=1; }
  booch_uv_tool_ensure ansible-core 3.12
  assert_eq "ansible-core" "$up_args"
  assert_eq "0" "$inst_called" "導入済みなら install しない"
}
test_uv_tool_ensure_installs_with_python_when_absent() {
  booch_uv_tool_installed() { return 1; }
  local inst_args="__unset__"
  booch_uv_tool_install() { inst_args="$*"; }
  booch_uv_tool_upgrade() { :; }
  booch_uv_tool_ensure ansible-core 3.12
  assert_eq "--python 3.12 ansible-core" "$inst_args"
}
test_uv_tool_ensure_installs_without_python() {
  booch_uv_tool_installed() { return 1; }
  local inst_args="__unset__"
  booch_uv_tool_install() { inst_args="$*"; }
  booch_uv_tool_upgrade() { :; }
  booch_uv_tool_ensure ruff
  assert_eq "ruff" "$inst_args"
}
# 第3引数 force で install に --force が付く（pipx 等の他管理実行ファイル上書き用）。
test_uv_tool_ensure_force_passes_force_flag() {
  booch_uv_tool_installed() { return 1; }
  local inst_args="__unset__"
  booch_uv_tool_install() { inst_args="$*"; }
  booch_uv_tool_upgrade() { :; }
  booch_uv_tool_ensure ansible-core 3.12 force
  assert_eq "--force --python 3.12 ansible-core" "$inst_args"
}

# --- booch_uv_installed_version ---
test_uv_installed_version_parses() {
  booch_uv_present() { return 0; }
  uv() { echo "uv 0.5.0"; }
  assert_eq "0.5.0" "$(booch_uv_installed_version)"
}
test_uv_installed_version_empty_when_absent() {
  booch_uv_present() { return 1; }
  assert_eq "" "$(booch_uv_installed_version)"
}

run_tests
