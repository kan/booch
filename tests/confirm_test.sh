#!/usr/bin/env bash
# lib/confirm.sh のユニットテスト。tty プロンプト本体（booch_confirm_prompt）を
# スタブで差し替え、判断ロジックを決定論的に検証する。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/confirm.sh
source "$BOOCH_ROOT/lib/confirm.sh"

test_confirm_proceeds_when_not_installed() {
  local rc; if booch_confirm_update "X" "" "1.0" false; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

test_confirm_proceeds_when_assume_yes_even_if_differ() {
  local rc; if booch_confirm_update "X" "1.0" "2.0" true; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}
# truthy トークン yes / 1 も確認省略になる（case の網羅ガード）。
test_confirm_assume_yes_token_yes() {
  local rc; if booch_confirm_update "X" "1.0" "2.0" yes; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}
test_confirm_assume_yes_token_1() {
  local rc; if booch_confirm_update "X" "1.0" "2.0" 1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}
# 4 番目省略時の既定は false（確認省略しない＝プロンプトへ）。stub を no にして見送りを確認。
test_confirm_default_assume_yes_is_false() {
  booch_confirm_prompt() { return 1; }
  local rc; if booch_confirm_update "X" "1.0" "2.0" >/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

test_confirm_skips_when_latest_unknown() {
  local out rc
  if out=$(booch_confirm_update "X" "1.0" "" false); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "確認できませんでした"
}

test_confirm_proceeds_when_equal() {
  local rc; if booch_confirm_update "X" "1.0" "1.0" false; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

# 更新あり + ユーザーが承諾（プロンプトをスタブ）。
test_confirm_proceeds_when_user_confirms() {
  booch_confirm_prompt() { return 0; }
  local rc; if booch_confirm_update "X" "1.0" "2.0" false; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

# 更新あり + ユーザーが拒否（または tty 無し）。
test_confirm_skips_when_user_declines() {
  booch_confirm_prompt() { return 1; }
  local out rc
  if out=$(booch_confirm_update "X" "1.0" "2.0" false); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "スキップ"
}

run_tests
