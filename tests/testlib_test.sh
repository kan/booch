#!/usr/bin/env bash
# tests/lib.sh（テストフレームワーク）自体のユニットテスト。run_tests を別プロセスで
# 走らせ、途中の assert の失敗を取りこぼさないことを確かめる。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"

# 渡した定義の test_* だけを run_tests で走らせ、終了コードを返す。
# 外側の test_* を拾わないよう別プロセスで実行する。
_run_inner() { # shell-opts definitions
  bash "$1" -c 'source "$1"; eval "$2"; run_tests' _ "$TESTS_DIR/lib.sh" "$2" >/dev/null 2>&1
}

# 最後の行が成功しても、途中の assert が失敗したテストは FAIL になる。
# （if の条件の中で実行すると set -e が効かず、これを見逃していた。）
test_run_tests_fails_on_middle_assert() {
  local rc
  if _run_inner +e 'test_x() { assert_eq a b; true; }'; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# caller が set -e でも、失敗したテストで run_tests ごと抜けずに集計まで進む。
test_run_tests_under_errexit_counts_failure() {
  local rc
  if _run_inner -e 'test_x() { assert_eq a b; true; }; test_y() { true; }'; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# 全部成功なら 0。
test_run_tests_passes_when_all_ok() {
  local rc
  if _run_inner -e 'test_x() { assert_eq a a; true; }'; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

run_tests
