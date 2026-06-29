#!/usr/bin/env bash
# lib/verify.sh のユニットテスト。照合ロジック（booch_verify_sha256 / booch_verify_pick）を
# 実ファイル + 既知ハッシュで純粋に検証する（network 不要）。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/verify.sh
source "$BOOCH_ROOT/lib/verify.sh"

# "hello\n" の SHA256（printf 'hello\n' | sha256sum で確認できる既知値）。
HELLO_SHA=5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03

_mkfile() { # content -> path
  local p; p=$(mktemp)
  printf '%s' "$1" > "$p"
  printf '%s' "$p"
}

# --- booch_verify_sha256 ---
test_verify_sha256_matches() {
  local f; f=$(_mkfile $'hello\n')
  booch_verify_sha256 "$f" "$HELLO_SHA"
  rm -f "$f"
}

# 大文字 hex でも一致する（大小無視）。
test_verify_sha256_matches_uppercase() {
  local f; f=$(_mkfile $'hello\n')
  booch_verify_sha256 "$f" "${HELLO_SHA^^}"
  rm -f "$f"
}

test_verify_sha256_mismatch_fails() {
  local f rc; f=$(_mkfile $'hello\n')
  if booch_verify_sha256 "$f" "0000000000000000000000000000000000000000000000000000000000000000" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  rm -f "$f"
  assert_status 1 "$rc"
}

# 期待値が空（checksums から拾えなかった等）は不一致と同様に失敗させる。
test_verify_sha256_empty_expected_fails() {
  local f rc; f=$(_mkfile $'hello\n')
  if booch_verify_sha256 "$f" "" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  rm -f "$f"
  assert_status 1 "$rc"
}

# --- booch_verify_pick ---
_checksums() {
  printf '%s\n' \
    "aaaa  circleci-cli_1.2.3_linux_arm64.tar.gz" \
    "bbbb  circleci-cli_1.2.3_linux_amd64.tar.gz"
}

test_verify_pick_finds_asset() {
  assert_eq "bbbb" "$(_checksums | booch_verify_pick circleci-cli_1.2.3_linux_amd64.tar.gz)"
}

# BSD 形式（"<hash> *<filename>"）の先頭 * を外して照合する。
test_verify_pick_strips_bsd_star() {
  assert_eq "cccc" "$(printf '%s\n' 'cccc *go1.99.0.linux-amd64.tar.gz' | booch_verify_pick go1.99.0.linux-amd64.tar.gz)"
}

# 該当行が無ければ非 0（空出力）。
test_verify_pick_missing_fails() {
  local out rc
  if out=$(_checksums | booch_verify_pick nope.tar.gz); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "" "$out"
}

run_tests
