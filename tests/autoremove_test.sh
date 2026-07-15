#!/usr/bin/env bash
# lib/autoremove.sh のユニットテスト。差分計算（desired に無い id を plan 行にする）を検証する。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/autoremove.sh
source "$BOOCH_ROOT/lib/autoremove.sh"

# desired に無い id だけが plan 行になる。plan は "<kind>\t<id>\t<desc>"。
test_diff_emits_only_undesired() {
  local out
  out=$(printf 'a\nb\nc\n' | booch_autoremove_diff plugin "リスト外" a c)
  assert_eq "$(printf 'plugin\tb\tリスト外')" "$out"
}

# desired に全て含まれれば出力なし。
test_diff_all_desired_empty() {
  local out
  out=$(printf 'a\nb\n' | booch_autoremove_diff plugin "x" a b)
  assert_eq "" "$out"
}

# desired が空なら全件が plan になる。
test_diff_empty_desired_all_undesired() {
  local out
  out=$(printf 'a\nb\n' | booch_autoremove_diff mcpserver "外")
  assert_eq "$(printf 'mcpserver\ta\t外\nmcpserver\tb\t外')" "$out"
}

# 空行は読み飛ばす（列挙コマンドの末尾空行で空 id を出さない）。
test_diff_skips_blank_lines() {
  local out
  out=$(printf 'a\n\n\nb\n' | booch_autoremove_diff k "d" a)
  assert_eq "$(printf 'k\tb\td')" "$out"
}

# id 比較は完全一致（部分一致で誤除外しない）。
test_diff_exact_match_only() {
  local out
  out=$(printf 'acme-tools@acme\n' | booch_autoremove_diff plugin "外" acme-tools@acme2)
  assert_eq "$(printf 'plugin\tacme-tools@acme\t外')" "$out"
}

# 空白を含む id も 1 件として扱う（read -r で行単位）。
test_diff_preserves_spaces_in_id() {
  local out
  out=$(printf 'a b\n' | booch_autoremove_diff k "d" x)
  assert_eq "$(printf 'k\ta b\td')" "$out"
}

run_tests
