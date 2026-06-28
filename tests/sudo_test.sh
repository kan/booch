#!/usr/bin/env bash
# lib/sudo.sh のユニットテスト。sudo の実呼び出し（validate/refresh）を seam で差し替え、
# prime/stop のロジックを実 sudo 無しで検証する。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# stub（validate/refresh）は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/sudo.sh
source "$BOOCH_ROOT/lib/sudo.sh"

test_sudo_prime_fails_when_validate_fails() {
  booch_sudo_validate() { return 1; }
  local rc; if booch_sudo_prime; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "" "$BOOCH_SUDO_KEEPALIVE_PID" "失敗時はキープアライブを開始しない"
}

test_sudo_prime_starts_keepalive_when_ok() {
  booch_sudo_validate() { return 0; }
  booch_sudo_refresh() { return 1; }   # bg ループは即抜ける（残留プロセス回避）
  booch_sudo_prime
  local ok="no"; [ -n "$BOOCH_SUDO_KEEPALIVE_PID" ] && ok="yes"
  booch_sudo_stop
  assert_eq "yes" "$ok" "成功時はキープアライブ PID を持つ"
}

test_sudo_stop_clears_pid() {
  booch_sudo_validate() { return 0; }
  booch_sudo_refresh() { return 1; }
  booch_sudo_prime
  booch_sudo_stop
  assert_eq "" "$BOOCH_SUDO_KEEPALIVE_PID" "停止で PID をクリアする"
}

run_tests
