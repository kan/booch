#!/usr/bin/env bash
# jobs/aws.sh のユニットテスト。seam をスタブで差し替え、AWS CLI / SSM の分岐と
# arch / deb-dir の純粋ロジックを検証する（実 install 不要）。

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
# shellcheck source=jobs/aws.sh
source "$BOOCH_ROOT/jobs/aws.sh"

# --- 純粋: arch / deb-dir ---
test_aws_arch_x86_64() { uname() { echo x86_64; }; assert_eq "x86_64" "$(booch_aws_arch)"; }
test_aws_arch_aarch64() { uname() { echo aarch64; }; assert_eq "aarch64" "$(booch_aws_arch)"; }
test_aws_arch_unsupported_fails() {
  uname() { echo riscv64; }
  local rc; if booch_aws_arch >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
test_aws_ssm_deb_dir_x86_64() { assert_eq "ubuntu_64bit" "$(booch_aws_ssm_deb_dir x86_64)"; }
test_aws_ssm_deb_dir_aarch64() { assert_eq "ubuntu_arm64" "$(booch_aws_ssm_deb_dir aarch64)"; }
test_aws_ssm_deb_dir_unsupported_fails() {
  local rc; if booch_aws_ssm_deb_dir mips >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# job_aws 全体のセットアップ。CLI の現在/最新、SSM の前後版をパラメータ化する。
# $1=cli_cur $2=cli_latest $3=ssm_before $4=ssm_after
_run_job_aws() {
  booch_runner_init
  local _cc=$1 _cl=$2 _sb=$3 _sa=$4
  booch_aws_arch() { echo x86_64; }
  booch_aws_cli_installed_version() { printf '%s' "$_cc"; }
  booch_aws_cli_latest() { printf '%s' "$_cl"; }
  booch_aws_cli_install() { :; }
  # SSM は install 前後で版が変わる挙動を、グローバルなフラグで再現する。
  _ssm_done=0
  booch_aws_ssm_installed_version() { if [ "$_ssm_done" -eq 0 ]; then printf '%s' "$_sb"; else printf '%s' "$_sa"; fi; }
  booch_aws_ssm_install() { _ssm_done=1; }
  export BOOCH_JOB=aws
  job_aws
}

# --- AWS CLI 分岐（SSM は据え置き=current にして CLI 行だけ見る） ---
test_aws_cli_installs_when_missing() {
  _run_job_aws "" "2.20.0" "1.2.3" "1.2.3"
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "AWS CLI|installed||2.20.0"
}
test_aws_cli_updates_when_differ() {
  _run_job_aws "2.19.0" "2.20.0" "1.2.3" "1.2.3"
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "AWS CLI|updated|2.19.0|2.20.0"
}
test_aws_cli_current_when_equal() {
  _run_job_aws "2.20.0" "2.20.0" "1.2.3" "1.2.3"
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "AWS CLI|current|2.20.0"
}

# --- SSM 分岐（前後版で installed/updated/current を出し分け） ---
test_aws_ssm_installed_when_missing_before() {
  _run_job_aws "2.20.0" "2.20.0" "" "1.2.3"
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "SSM Plugin|installed||1.2.3"
}
# SSM は upstream に版確認手段が無いため「未導入時のみ導入」。導入済みなら再導入せず
# current を出す（毎回再取得しない＝冪等性の回帰ガード）。
# shellcheck disable=SC2317  # install スタブは job 経由でのみ呼ばれる
test_aws_ssm_current_and_no_reinstall_when_present() {
  booch_runner_init
  booch_aws_arch() { echo x86_64; }
  booch_aws_cli_installed_version() { printf '2.20.0'; }
  booch_aws_cli_latest() { printf '2.20.0'; }
  booch_aws_cli_install() { :; }
  booch_aws_ssm_installed_version() { printf '1.2.3'; }
  local ssm_installed=0
  booch_aws_ssm_install() { ssm_installed=1; }
  export BOOCH_JOB=aws
  job_aws
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "SSM Plugin|current|1.2.3"
  assert_eq "0" "$ssm_installed" "導入済みなら再導入しない（冪等）"
}
test_aws_ssm_current_when_same() {
  _run_job_aws "2.20.0" "2.20.0" "1.2.3" "1.2.3"
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "SSM Plugin|current|1.2.3"
}

# --- 失敗系 ---
test_aws_fails_when_arch_unsupported() {
  booch_runner_init
  booch_aws_arch() { return 1; }
  export BOOCH_JOB=aws
  local rc; if job_aws >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
test_aws_fails_when_cli_latest_unavailable() {
  booch_runner_init
  booch_aws_arch() { echo x86_64; }
  booch_aws_cli_installed_version() { printf '2.19.0'; }
  booch_aws_cli_latest() { return 1; }
  booch_aws_cli_install() { :; }
  export BOOCH_JOB=aws
  local rc; if job_aws >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$BOOCH_RESULT_DIR/aws.result"
}
# curl 成功でも版が空（CHANGELOG 形式変化等）なら、空版での誤 update をせず失敗する。
test_aws_fails_when_cli_latest_empty() {
  booch_runner_init
  booch_aws_arch() { echo x86_64; }
  booch_aws_cli_installed_version() { printf '2.20.0'; }
  booch_aws_cli_latest() { printf ''; }   # rc 0 だが空
  local install_called=0
  booch_aws_cli_install() { install_called=1; }
  export BOOCH_JOB=aws
  local rc; if job_aws >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "0" "$install_called" "空版では install しない"
  assert_file_absent "$BOOCH_RESULT_DIR/aws.result"
}

# --- 資産 URL / arch の install への受け渡し（curl 直叩きを fetch 不要で確認） ---
# CLI install は curl を直接使うため、curl を関数で差し替えて URL を捕捉する。
# shellcheck disable=SC2317  # curl/unzip/sudo は install 内からのみ呼ばれる
test_aws_cli_install_uses_arch_in_url() {
  local cap_url=""
  curl() { while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) cap_url=$1; shift ;; esac; done; return 1; }
  local rc; if booch_aws_cli_install aarch64 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" "$cap_url"
}

# SSM install の URL に arch 由来の deb ディレクトリ（aarch64 → ubuntu_arm64）が入る。
# shellcheck disable=SC2317  # curl/dpkg/sudo は install 内からのみ呼ばれる
test_aws_ssm_install_uses_arch_dir_in_url() {
  local cap_url=""
  curl() { while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) cap_url=$1; shift ;; esac; done; return 1; }
  local rc; if booch_aws_ssm_install aarch64 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" "$cap_url"
}

run_tests
