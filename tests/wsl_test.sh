#!/usr/bin/env bash
# lib/wsl.sh のユニットテスト。判定 seam をスタブして検証する。

# stub は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317
TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/wsl.sh
source "$BOOCH_ROOT/lib/wsl.sh"

# --- booch_wsl_is_wsl（grep / 環境変数で制御） ---
test_is_wsl_true_via_env() {
  grep() { return 1; }   # /proc/version は microsoft 無し
  WSL_DISTRO_NAME=Ubuntu
  local rc; if booch_wsl_is_wsl; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

test_is_wsl_true_via_proc() {
  grep() { return 0; }   # /proc/version に microsoft あり
  unset WSL_DISTRO_NAME
  local rc; if booch_wsl_is_wsl; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

test_is_wsl_false() {
  grep() { return 1; }
  unset WSL_DISTRO_NAME
  local rc; if booch_wsl_is_wsl; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- booch_wsl_doctor_interop（is_wsl / registered / persisted を seam で固定） ---
test_doctor_interop_noop_when_not_wsl() {
  booch_wsl_is_wsl() { return 1; }
  local out; out=$(booch_wsl_doctor_interop)
  assert_eq "" "$out"   # 非 WSL は何も出さない
}

test_doctor_interop_ok_when_all_good() {
  booch_wsl_is_wsl() { return 0; }
  booch_wsl_interop_registered() { return 0; }
  booch_wsl_interop_persisted() { return 0; }
  local rc; if booch_wsl_doctor_interop >/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"   # 警告なし → 0
}

test_doctor_interop_warns_when_not_registered() {
  booch_wsl_is_wsl() { return 0; }
  booch_wsl_interop_registered() { return 1; }
  booch_wsl_interop_persisted() { return 0; }
  local out rc
  out=$(booch_wsl_doctor_interop) && rc=0 || rc=$?
  assert_status 1 "$rc"
  assert_contains "$out" "WSLInterop disabled"
}

test_doctor_interop_warns_when_not_persisted() {
  booch_wsl_is_wsl() { return 0; }
  booch_wsl_interop_registered() { return 0; }
  booch_wsl_interop_persisted() { return 1; }
  local out rc
  out=$(booch_wsl_doctor_interop) && rc=0 || rc=$?
  assert_status 1 "$rc"
  assert_contains "$out" "not persisted"
}

run_tests
