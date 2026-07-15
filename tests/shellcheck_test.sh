#!/usr/bin/env bash
# jobs/shellcheck.sh のユニットテスト。seam をスタブで差し替え、版解析・arch・資産名・
# job 分岐を検証する（実ツール・ネットワーク不要）。

# stub（shellcheck/uname/seam）は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317,SC2329
TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/runner.sh
source "$BOOCH_ROOT/lib/runner.sh"
# shellcheck source=lib/arch.sh
source "$BOOCH_ROOT/lib/arch.sh"
# shellcheck source=lib/github.sh
source "$BOOCH_ROOT/lib/github.sh"
# shellcheck source=jobs/shellcheck.sh
source "$BOOCH_ROOT/jobs/shellcheck.sh"

# --- バージョン解析（"version:" 行から版だけを取る） ---
test_shellcheck_installed_version_parses_version_line() {
  # stub 関数を定義すると command -v shellcheck が関数として真になり、実解析を通せる。
  shellcheck() { printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\nlicense: GPLv3\n'; }
  assert_eq "0.11.0" "$(booch_shellcheck_installed_version)"
}
test_shellcheck_installed_version_empty_when_absent() {
  # PATH を空にして command -v shellcheck を偽（未導入）にすると空を返す
  local out; out=$(PATH='' booch_shellcheck_installed_version 2>/dev/null)
  assert_eq "" "$out"
}

# --- 純粋関数 / arch ---
test_shellcheck_asset_name() {
  assert_eq "shellcheck-v0.11.0.linux.x86_64.tar.xz" "$(booch_shellcheck_asset v0.11.0 x86_64)"
  assert_eq "shellcheck-v0.11.0.linux.aarch64.tar.xz" "$(booch_shellcheck_asset v0.11.0 aarch64)"
}
test_shellcheck_arch_x86_64() {
  uname() { echo x86_64; }
  assert_eq "x86_64" "$(booch_shellcheck_arch)"
}
test_shellcheck_arch_aarch64() {
  uname() { echo aarch64; }
  assert_eq "aarch64" "$(booch_shellcheck_arch)"
}
test_shellcheck_arch_unsupported_fails() {
  uname() { echo riscv64; }
  local rc; if booch_shellcheck_arch >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- job_shellcheck 分岐（実処理はスタブ。latest は v 付きタグを返す） ---
_run_job_shellcheck() { # installed latest_tag
  booch_runner_init
  local _inst=$1 _lat=$2
  booch_shellcheck_arch() { echo x86_64; }
  booch_shellcheck_installed_version() { printf '%s' "$_inst"; }
  booch_shellcheck_latest() { printf '%s' "$_lat"; }
  booch_shellcheck_install() { :; }
  export BOOCH_JOB=shellcheck
  job_shellcheck
}

test_shellcheck_installs_when_missing() {
  _run_job_shellcheck "" "v0.11.0"
  assert_eq "ShellCheck|installed||0.11.0" "$(cat "$BOOCH_RESULT_DIR/shellcheck.result")"
}
test_shellcheck_updates_when_differ() {
  _run_job_shellcheck "0.10.0" "v0.11.0"
  assert_eq "ShellCheck|updated|0.10.0|0.11.0" "$(cat "$BOOCH_RESULT_DIR/shellcheck.result")"
}
# v 正規化により、素のバージョンとタグが同一なら current（永久更新にならない）。
test_shellcheck_current_when_equal_after_normalize() {
  _run_job_shellcheck "0.11.0" "v0.11.0"
  assert_eq "ShellCheck|current|0.11.0|" "$(cat "$BOOCH_RESULT_DIR/shellcheck.result")"
}

run_tests
