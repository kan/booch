#!/usr/bin/env bash
# jobs/starship.sh のユニットテスト。seam をスタブで差し替え、分岐・基底名・arch・
# 資産名（.sha256 含む）を検証する。

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
# shellcheck source=lib/verify.sh
source "$BOOCH_ROOT/lib/verify.sh"
# shellcheck source=jobs/starship.sh
source "$BOOCH_ROOT/jobs/starship.sh"

# --- バージョン解析（starship を関数で差し替え。実解析を通す） ---
test_starship_installed_version_parses_version() {
  starship() { echo "starship 1.26.0"; }
  assert_eq "1.26.0" "$(booch_starship_installed_version)"
}
# 末尾にハッシュ等が付いても X.Y.Z を拾う（位置依存の脆さに対する回帰ガード）。
test_starship_installed_version_robust_to_trailing_token() {
  starship() { echo "starship 1.26.0 (abcdef)"; }
  assert_eq "1.26.0" "$(booch_starship_installed_version)"
}

# --- 純粋関数 / arch ---
test_starship_artifact_name() {
  assert_eq "starship-x86_64-unknown-linux-musl" "$(booch_starship_artifact x86_64)"
}
test_starship_arch_x86_64() {
  uname() { echo x86_64; }
  assert_eq "x86_64" "$(booch_starship_arch)"
}
test_starship_arch_aarch64() {
  uname() { echo aarch64; }
  assert_eq "aarch64" "$(booch_starship_arch)"
}
test_starship_arch_unsupported_fails() {
  uname() { echo riscv64; }
  local rc; if booch_starship_arch >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- job_starship 分岐（実処理はスタブ。latest は v 付きタグを返す） ---
_run_job_starship() { # installed latest_tag
  booch_runner_init
  local _inst=$1 _lat=$2
  booch_starship_arch() { echo x86_64; }
  booch_starship_installed_version() { printf '%s' "$_inst"; }
  booch_starship_latest() { printf '%s' "$_lat"; }
  booch_starship_install() { :; }
  export BOOCH_JOB=starship
  job_starship
}

test_starship_installs_when_missing() {
  _run_job_starship "" "v1.26.0"
  assert_eq "Starship|installed||1.26.0" "$(cat "$BOOCH_RESULT_DIR/starship.result")"
}
test_starship_updates_when_differ() {
  _run_job_starship "1.25.1" "v1.26.0"
  assert_eq "Starship|updated|1.25.1|1.26.0" "$(cat "$BOOCH_RESULT_DIR/starship.result")"
}
# v 正規化により、素のバージョンとタグが同一なら current（永久更新にならない）。
test_starship_current_when_equal_after_normalize() {
  _run_job_starship "1.26.0" "v1.26.0"
  assert_eq "Starship|current|1.26.0|" "$(cat "$BOOCH_RESULT_DIR/starship.result")"
}

test_starship_fails_when_latest_unavailable() {
  booch_runner_init
  booch_starship_arch() { echo x86_64; }
  booch_starship_installed_version() { printf '1.25.1'; }
  booch_starship_latest() { return 1; }
  booch_starship_install() { :; }
  export BOOCH_JOB=starship
  local rc; if job_starship >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$BOOCH_RESULT_DIR/starship.result"
}

test_starship_fails_when_arch_unsupported() {
  booch_runner_init
  booch_starship_arch() { return 1; }
  export BOOCH_JOB=starship
  local rc; if job_starship >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# install が download に渡す資産名が正しい（sudo へ到達しないよう download スタブは
# 捕捉して非 0 を返す）。1 回目の呼び出し（tar.gz 本体）の資産名を検証する。
test_starship_install_passes_correct_asset() {
  local cap_repo="" cap_asset=""
  booch_github_download_asset() { cap_repo=$1; cap_asset=$3; return 1; }
  local rc; if booch_starship_install v1.26.0 x86_64; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "starship/starship" "$cap_repo"
  assert_eq "starship-x86_64-unknown-linux-musl.tar.gz" "$cap_asset"
}

# .sha256 が不一致なら展開・install へ進まず失敗する（検証ゲートの回帰ガード）。
# download スタブは tar.gz と .sha256 を temp に用意し、verify を不一致に固定する。
test_starship_install_aborts_on_sha256_mismatch() {
  booch_github_download_asset() { : >"$4"; return 0; }   # 空ファイルを置くだけ
  booch_verify_sha256() { return 1; }                    # 常に不一致
  local reached_install=0
  # sudo に到達したら install まで進んでしまった証拠（本来は verify で止まるべき）。
  sudo() { reached_install=1; return 0; }
  local rc; if booch_starship_install v1.26.0 x86_64 >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "0" "$reached_install"
}

# --- runner 経由（declare -f 伝播＋失敗時の自動 failed 記録） ---
# shellcheck disable=SC2317  # スタブは runner の bash -c 子経由でのみ呼ばれる
test_starship_via_runner_reports_installed() {
  booch_runner_init
  booch_starship_arch() { echo x86_64; }
  booch_starship_installed_version() { printf ''; }
  booch_starship_latest() { printf 'v1.26.0'; }
  booch_starship_install() { :; }
  booch_job starship "Starship" job_starship 60
  local out; out=$(booch_run)
  assert_contains "$out" "Starship"
  assert_contains "$out" "installed"
  assert_contains "$out" "1.26.0"
}

# shellcheck disable=SC2317
test_starship_via_runner_install_failure_is_failed() {
  booch_runner_init
  booch_starship_arch() { echo x86_64; }
  booch_starship_installed_version() { printf ''; }
  booch_starship_latest() { printf 'v1.26.0'; }
  booch_starship_install() { return 1; }
  booch_job starship "Starship" job_starship 60
  local out rc; if out=$(booch_run); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "failed"
}

run_tests
