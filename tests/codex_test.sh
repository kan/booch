#!/usr/bin/env bash
# jobs/codex.sh のユニットテスト。seam をスタブで差し替え、分岐・基底名・arch を検証する。

# stub（uname/seam）は間接呼び出しで shellcheck から到達不能に見える
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
# shellcheck source=jobs/codex.sh
source "$BOOCH_ROOT/jobs/codex.sh"

# --- バージョン解析（codex を関数で差し替え。実解析を通す） ---
test_codex_installed_version_parses_version() {
  codex() { echo "codex-cli 0.142.3"; }
  assert_eq "0.142.3" "$(booch_codex_installed_version)"
}
# 末尾にハッシュ等が付いても X.Y.Z を拾う（$NF 方式の脆さに対する回帰ガード）。
test_codex_installed_version_robust_to_trailing_token() {
  codex() { echo "codex-cli 0.142.3 (abcdef)"; }
  assert_eq "0.142.3" "$(booch_codex_installed_version)"
}

# --- 純粋関数 / arch ---
test_codex_artifact_name() {
  assert_eq "codex-x86_64-unknown-linux-musl" "$(booch_codex_artifact x86_64)"
}
test_codex_arch_x86_64() {
  uname() { echo x86_64; }
  assert_eq "x86_64" "$(booch_codex_arch)"
}
test_codex_arch_aarch64() {
  uname() { echo aarch64; }
  assert_eq "aarch64" "$(booch_codex_arch)"
}
test_codex_arch_unsupported_fails() {
  uname() { echo riscv64; }
  local rc; if booch_codex_arch >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- job_codex 分岐（実処理はスタブ。latest は rust-v 付きを返す） ---
_run_job_codex() { # installed latest_tag
  booch_runner_init
  local _inst=$1 _lat=$2
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf '%s' "$_inst"; }
  booch_codex_latest() { printf '%s' "$_lat"; }
  booch_codex_install() { :; }
  export BOOCH_JOB=codex
  job_codex
}

test_codex_installs_when_missing() {
  _run_job_codex "" "rust-v0.20.0"
  assert_eq "Codex CLI|installed||0.20.0" "$(cat "$BOOCH_RESULT_DIR/codex.result")"
}
test_codex_updates_when_differ() {
  _run_job_codex "0.19.0" "rust-v0.20.0"
  assert_eq "Codex CLI|updated|0.19.0|0.20.0" "$(cat "$BOOCH_RESULT_DIR/codex.result")"
}
# rust-v 正規化により、素のバージョンとタグが同一なら current（永久更新にならない）。
test_codex_current_when_equal_after_normalize() {
  _run_job_codex "0.20.0" "rust-v0.20.0"
  assert_eq "Codex CLI|current|0.20.0|" "$(cat "$BOOCH_RESULT_DIR/codex.result")"
}
# v 単独タグでも 2 段目の strip で正規化され current（${norm#v} の回帰ガード）。
test_codex_current_when_tag_has_v_prefix() {
  _run_job_codex "0.20.0" "v0.20.0"
  assert_eq "Codex CLI|current|0.20.0|" "$(cat "$BOOCH_RESULT_DIR/codex.result")"
}

test_codex_fails_when_latest_unavailable() {
  booch_runner_init
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf '0.19.0'; }
  booch_codex_latest() { return 1; }
  booch_codex_install() { :; }
  export BOOCH_JOB=codex
  local rc; if job_codex >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$BOOCH_RESULT_DIR/codex.result"
}

test_codex_fails_when_arch_unsupported() {
  booch_runner_init
  booch_codex_arch() { return 1; }
  export BOOCH_JOB=codex
  local rc; if job_codex >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# install が download に渡す資産名が正しい（dpkg/sudo へ到達しないよう download
# スタブは捕捉して非 0 を返す）。捕捉変数は install のローカルと衝突しない名前。
test_codex_install_passes_correct_asset() {
  local cap_repo="" cap_asset=""
  booch_github_download_asset() { cap_repo=$1; cap_asset=$3; return 1; }
  local rc; if booch_codex_install rust-v0.20.0 x86_64; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "openai/codex" "$cap_repo"
  assert_eq "codex-x86_64-unknown-linux-musl.tar.gz" "$cap_asset"
}

# --- runner 経由（declare -f 伝播＋失敗時の自動 failed 記録） ---
# shellcheck disable=SC2317,SC2329  # スタブは runner の bash -c 子経由でのみ呼ばれる
test_codex_via_runner_reports_installed() {
  booch_runner_init
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf ''; }
  booch_codex_latest() { printf 'rust-v0.20.0'; }
  booch_codex_install() { :; }
  booch_job codex "Codex CLI" job_codex 60
  local out; out=$(booch_run)
  assert_contains "$out" "Codex CLI"
  assert_contains "$out" "installed"
  assert_contains "$out" "0.20.0"
}

# shellcheck disable=SC2317,SC2329
test_codex_via_runner_install_failure_is_failed() {
  booch_runner_init
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf ''; }
  booch_codex_latest() { printf 'rust-v0.20.0'; }
  booch_codex_install() { return 1; }
  booch_job codex "Codex CLI" job_codex 60
  local out rc; if out=$(booch_run); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "failed"
}

run_tests
