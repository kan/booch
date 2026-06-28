#!/usr/bin/env bash
# jobs/circleci.sh のユニットテスト。seam をスタブで差し替え、分岐・基底名・arch を検証する。

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
# shellcheck source=lib/github.sh
source "$BOOCH_ROOT/lib/github.sh"
# shellcheck source=jobs/circleci.sh
source "$BOOCH_ROOT/jobs/circleci.sh"

# --- 純粋 / arch ---
test_circleci_asset_base() {
  assert_eq "circleci-cli_0.1.38646_linux_amd64" "$(booch_circleci_asset_base 0.1.38646 amd64)"
}
test_circleci_arch_amd64() { uname() { echo x86_64; }; assert_eq "amd64" "$(booch_circleci_arch)"; }
test_circleci_arch_arm64() { uname() { echo aarch64; }; assert_eq "arm64" "$(booch_circleci_arch)"; }
test_circleci_arch_unsupported_fails() {
  uname() { echo riscv64; }
  local rc; if booch_circleci_arch >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- job_circleci 分岐（latest は v 付きタグを返す。ver は v を外した値で比較/表示） ---
_run_job_circleci() { # installed latest_tag
  booch_runner_init
  local _inst=$1 _lat=$2
  booch_circleci_arch() { echo amd64; }
  booch_circleci_installed_version() { printf '%s' "$_inst"; }
  booch_circleci_latest() { printf '%s' "$_lat"; }
  booch_circleci_install() { :; }
  export BOOCH_JOB=circleci
  job_circleci
}

test_circleci_installs_when_missing() {
  _run_job_circleci "" "v0.1.38646"
  assert_eq "CircleCI CLI|installed||0.1.38646" "$(cat "$BOOCH_RESULT_DIR/circleci.result")"
}
test_circleci_updates_when_differ() {
  _run_job_circleci "0.1.38000" "v0.1.38646"
  assert_eq "CircleCI CLI|updated|0.1.38000|0.1.38646" "$(cat "$BOOCH_RESULT_DIR/circleci.result")"
}
test_circleci_current_when_equal_after_v_strip() {
  _run_job_circleci "0.1.38646" "v0.1.38646"
  assert_eq "CircleCI CLI|current|0.1.38646|" "$(cat "$BOOCH_RESULT_DIR/circleci.result")"
}

test_circleci_fails_when_latest_unavailable() {
  booch_runner_init
  booch_circleci_arch() { echo amd64; }
  booch_circleci_installed_version() { printf '0.1.38000'; }
  booch_circleci_latest() { return 1; }
  booch_circleci_install() { :; }
  export BOOCH_JOB=circleci
  local rc; if job_circleci >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$BOOCH_RESULT_DIR/circleci.result"
}

test_circleci_fails_when_arch_unsupported() {
  booch_runner_init
  booch_circleci_arch() { return 1; }
  export BOOCH_JOB=circleci
  local rc; if job_circleci >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# install が download に渡す資産名が正しい（tag は v 付き、asset は v なし base）。
test_circleci_install_passes_correct_asset() {
  local cap_repo="" cap_tag="" cap_asset=""
  booch_github_download_asset() { cap_repo=$1; cap_tag=$2; cap_asset=$3; return 1; }
  local rc; if booch_circleci_install v0.1.38646 amd64; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "CircleCI-Public/circleci-cli" "$cap_repo"
  assert_eq "v0.1.38646" "$cap_tag"
  assert_eq "circleci-cli_0.1.38646_linux_amd64.tar.gz" "$cap_asset"
}

run_tests
