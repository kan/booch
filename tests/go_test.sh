#!/usr/bin/env bash
# jobs/go.sh のユニットテスト。継ぎ目（booch_go_*）をスタブで差し替え、
# ネットワーク / sudo 無しで分岐を検証する。

# stub（uname/seam）は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317
TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/runner.sh
source "$BOOCH_ROOT/lib/runner.sh"
# shellcheck source=lib/arch.sh
source "$BOOCH_ROOT/lib/arch.sh"
# shellcheck source=jobs/go.sh
source "$BOOCH_ROOT/jobs/go.sh"

# job_go を直接呼び、書かれた結果行を確認する。実処理（導入）は no-op。
# 版はローカル変数で渡す（bash の動的スコープでスタブから参照できる。eval 不要）。
# $1=installed version（空で未導入）, $2=latest version（空で取得失敗）
_run_job_go() {
  booch_runner_init
  local _stub_installed=$1 _stub_latest=$2
  booch_go_installed_version() { printf '%s' "$_stub_installed"; }
  booch_go_latest_version() { printf '%s' "$_stub_latest"; }
  booch_go_install() { :; }
  export BOOCH_JOB=go
  job_go
}

test_go_installs_when_missing() {
  _run_job_go "" "go1.99.0"
  assert_eq "Go|installed||go1.99.0" "$(cat "$BOOCH_RESULT_DIR/go.result")"
}

test_go_updates_when_version_differs() {
  _run_job_go "go1.98.0" "go1.99.0"
  assert_eq "Go|updated|go1.98.0|go1.99.0" "$(cat "$BOOCH_RESULT_DIR/go.result")"
}

test_go_current_when_up_to_date() {
  _run_job_go "go1.99.0" "go1.99.0"
  assert_eq "Go|current|go1.99.0|" "$(cat "$BOOCH_RESULT_DIR/go.result")"
}

# 最新版を取得できないときは導入を試みず失敗する（未導入扱いで空版を入れない）。
test_go_fails_when_latest_unavailable() {
  local rc
  if _run_job_go "go1.98.0" "" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$BOOCH_RESULT_DIR/go.result"
}

# --- arch 検出（uname を関数で差し替え。実機アーキに依存しない） ---
test_go_arch_amd64() {
  uname() { echo x86_64; }
  assert_eq "amd64" "$(booch_go_arch)"
}

test_go_arch_arm64() {
  uname() { echo aarch64; }
  assert_eq "arm64" "$(booch_go_arch)"
}

test_go_arch_unknown_fails() {
  uname() { echo mips; }
  local rc
  if booch_go_arch >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- runner 経由の結合テスト（declare -f でスタブが子へ運ばれることまで検証） ---
# スタブは runner の bash -c 子経由でのみ呼ばれ shellcheck からは到達不能に見える。
# shellcheck disable=SC2317
test_go_via_runner_reports_current() {
  booch_runner_init
  booch_go_installed_version() { printf 'go1.99.0'; }
  booch_go_latest_version() { printf 'go1.99.0'; }
  booch_go_install() { :; }
  booch_job go "Go" job_go 60
  local out
  out=$(booch_run)
  assert_contains "$out" "latest"
  assert_contains "$out" "go1.99.0"
}

# 導入が失敗するとジョブは booch_result 到達前に abort するが、runner が failed 行を
# 補う（_booch_exec の自動 failed 記録を実ジョブで確認する）。
# shellcheck disable=SC2317
test_go_via_runner_install_failure_is_failed() {
  booch_runner_init
  booch_go_installed_version() { printf ''; }
  booch_go_latest_version() { printf 'go1.99.0'; }
  booch_go_install() { return 1; }
  booch_job go "Go" job_go 60
  local out rc
  if out=$(booch_run); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "failed"
}

run_tests
