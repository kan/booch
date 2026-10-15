#!/usr/bin/env bash
# jobs/aws.sh のユニットテスト。seam をスタブで差し替え、AWS CLI / SSM の分岐と
# arch / deb-dir の純粋ロジックを検証する（実 install 不要）。

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

# job_aws 全体のセットアップ。CLI の現在/最新、SSM の前後版と最新をパラメータ化する。
# $1=cli_cur $2=cli_latest $3=ssm_before $4=ssm_after [$5=ssm_latest（既定は $4）]
_run_job_aws() {
  booch_runner_init
  local _cc=$1 _cl=$2 _sb=$3 _sa=$4 _sl=${5-$4}
  booch_aws_arch() { echo x86_64; }
  booch_aws_cli_installed_version() { printf '%s' "$_cc"; }
  booch_aws_cli_latest() { printf '%s' "$_cl"; }
  booch_aws_cli_install() { :; }
  # SSM は install 前後で版が変わる挙動を、グローバルなフラグで再現する。
  _ssm_done=0
  booch_aws_ssm_installed_version() { if [ "$_ssm_done" -eq 0 ]; then printf '%s' "$_sb"; else printf '%s' "$_sa"; fi; }
  booch_aws_ssm_latest() { printf '%s' "$_sl"; }
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
# 最新と同じなら再導入しない（毎回 deb を落とし直さない＝冪等性の回帰ガード）。
# shellcheck disable=SC2317,SC2329  # install スタブは job 経由でのみ呼ばれる
test_aws_ssm_current_and_no_reinstall_when_present() {
  booch_runner_init
  booch_aws_arch() { echo x86_64; }
  booch_aws_cli_installed_version() { printf '2.20.0'; }
  booch_aws_cli_latest() { printf '2.20.0'; }
  booch_aws_cli_install() { :; }
  booch_aws_ssm_installed_version() { printf '1.2.3'; }
  booch_aws_ssm_latest() { printf '1.2.3'; }
  local ssm_installed=0
  booch_aws_ssm_install() { ssm_installed=1; }
  export BOOCH_JOB=aws
  job_aws
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "SSM Plugin|current|1.2.3"
  assert_eq "0" "$ssm_installed" "最新と同じなら再導入しない（冪等）"
}
test_aws_ssm_current_when_same() {
  _run_job_aws "2.20.0" "2.20.0" "1.2.3" "1.2.3"
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "SSM Plugin|current|1.2.3"
}
# upstream の /latest/VERSION が新しければ更新する（未導入時のみ導入だと初回の版で
# 凍結し、以後どれだけ古くなっても更新が入らなかったことの回帰ガード）。
test_aws_ssm_updates_when_latest_differs() {
  _run_job_aws "2.20.0" "2.20.0" "1.2.3" "1.3.0" "1.3.0"
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "SSM Plugin|updated|1.2.3|1.3.0"
}
# 版を取れないとき（オフライン等）は空版での誤 update をせず、導入済みは現状維持。
# shellcheck disable=SC2317,SC2329  # install スタブは job 経由でのみ呼ばれる
test_aws_ssm_keeps_current_when_latest_unavailable() {
  booch_runner_init
  booch_aws_arch() { echo x86_64; }
  booch_aws_cli_installed_version() { printf '2.20.0'; }
  booch_aws_cli_latest() { printf '2.20.0'; }
  booch_aws_cli_install() { :; }
  booch_aws_ssm_installed_version() { printf '1.2.3'; }
  booch_aws_ssm_latest() { return 1; }
  local ssm_installed=0
  booch_aws_ssm_install() { ssm_installed=1; }
  export BOOCH_JOB=aws
  job_aws
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "SSM Plugin|current|1.2.3"
  assert_eq "0" "$ssm_installed" "版不明のまま入れ直さない"
}
# 版を取れず未導入なら、従来どおり導入まではする（比較できないだけで導入は要る）。
test_aws_ssm_installs_when_latest_unavailable_and_missing() {
  _run_job_aws "2.20.0" "2.20.0" "" "1.2.3" ""
  assert_contains "$(cat "$BOOCH_RESULT_DIR/aws.result")" "SSM Plugin|installed||1.2.3"
}
# /latest/VERSION は改行を伴わずに返ることがある。空白・CR を落として比較可能にする。
# shellcheck disable=SC2317,SC2329  # curl は latest 内からのみ呼ばれる
test_aws_ssm_latest_normalizes_whitespace() {
  curl() { printf '  1.2.835.0\r\n'; }
  assert_eq "1.2.835.0" "$(booch_aws_ssm_latest)"
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
# shellcheck disable=SC2317,SC2329  # curl/unzip/sudo は install 内からのみ呼ばれる
test_aws_cli_install_uses_arch_in_url() {
  local cap_url=""
  curl() { while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) cap_url=$1; shift ;; esac; done; return 1; }
  local rc; if booch_aws_cli_install aarch64 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" "$cap_url"
}

# SSM install の URL に arch 由来の deb ディレクトリ（aarch64 → ubuntu_arm64）が入る。
# shellcheck disable=SC2317,SC2329  # curl/dpkg/sudo は install 内からのみ呼ばれる
test_aws_ssm_install_uses_arch_dir_in_url() {
  local cap_url=""
  curl() { while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) cap_url=$1; shift ;; esac; done; return 1; }
  local rc; if booch_aws_ssm_install aarch64 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" "$cap_url"
}

# --- AWS CLI の古い版（temp の導入先 / proc_exes をスタブ） ---
# 導入先に版ディレクトリを作る。current は最後の版を指し、その bin/aws は version_output を名乗る。
_aws_root() { # version_output ver...
  local out=$1 v; shift
  BOOCH_AWS_CLI_ROOT=$(mktemp -d)
  for v in "$@"; do mkdir -p "$BOOCH_AWS_CLI_ROOT/$v/bin"; done
  printf '#!/bin/sh\necho "%s Python/3.13"\n' "$out" > "$BOOCH_AWS_CLI_ROOT/$v/bin/aws"
  chmod +x "$BOOCH_AWS_CLI_ROOT/$v/bin/aws"
  ln -s "$BOOCH_AWS_CLI_ROOT/$v" "$BOOCH_AWS_CLI_ROOT/current"
  # 走査できた状態（少なくとも自分のシェルは読める）を既定にする。
  booch_aws_proc_exes() { echo /usr/bin/bash; }
}

test_aws_cli_stale_lists_versions_other_than_current() {
  _aws_root aws-cli/2.38.1 2.37.0 2.38.0 2.38.1
  assert_eq "$BOOCH_AWS_CLI_ROOT/2.37.0
$BOOCH_AWS_CLI_ROOT/2.38.0" "$(booch_aws_cli_stale_versions)"
  rm -rf "$BOOCH_AWS_CLI_ROOT"
}
# 壊れた導入（current の aws が自分の版を名乗らない）の上では何も消さない。
test_aws_cli_stale_empty_when_current_is_broken() {
  _aws_root "" 2.37.0 2.38.1
  assert_eq "" "$(booch_aws_cli_stale_versions)"
  rm -rf "$BOOCH_AWS_CLI_ROOT"
}
test_aws_cli_stale_empty_without_current() {
  BOOCH_AWS_CLI_ROOT=$(mktemp -d); mkdir -p "$BOOCH_AWS_CLI_ROOT/2.37.0"
  assert_eq "" "$(booch_aws_cli_stale_versions)"
  rm -rf "$BOOCH_AWS_CLI_ROOT"
}
# x.y.z 以外の名前と symlink には触らない。
test_aws_cli_stale_ignores_non_version_names_and_symlinks() {
  _aws_root aws-cli/2.38.1 2.38.1
  mkdir -p "$BOOCH_AWS_CLI_ROOT/backup" "$BOOCH_AWS_CLI_ROOT/2.38.0-rc"
  local other; other=$(mktemp -d)
  ln -s "$other" "$BOOCH_AWS_CLI_ROOT/2.30.0"
  assert_eq "" "$(booch_aws_cli_stale_versions)"
  rm -rf "$BOOCH_AWS_CLI_ROOT" "$other"
}
# 実行中のプロセスが使っている版は残す（開いたままの aws ssm start-session 等）。
test_aws_cli_stale_keeps_versions_in_use() {
  _aws_root aws-cli/2.38.1 2.37.0 2.38.0 2.38.1
  booch_aws_proc_exes() { printf '/usr/bin/bash\n%s/2.37.0/dist/aws\n' "$BOOCH_AWS_CLI_ROOT"; }
  assert_eq "$BOOCH_AWS_CLI_ROOT/2.38.0" "$(booch_aws_cli_stale_versions)"
  rm -rf "$BOOCH_AWS_CLI_ROOT"
}
# 削除側は sudo 付きで /proc を読み、root のプロセスが使う版も外す。
test_aws_cli_prune_reads_proc_with_sudo_and_removes() {
  _aws_root aws-cli/2.38.1 2.37.0 2.38.1
  # スタブは stale_versions の中から呼ばれ、そこでの local d に隠れるので別名にする。
  local capdir; capdir=$(mktemp -d)
  booch_aws_proc_exes() { echo "${1:-}" > "$capdir/proc_arg"; echo /usr/bin/bash; }
  sudo() { "$@"; }
  booch_aws_cli_prune >/dev/null
  assert_eq "sudo" "$(cat "$capdir/proc_arg")"
  assert_file_absent "$BOOCH_AWS_CLI_ROOT/2.37.0"
  [ -d "$BOOCH_AWS_CLI_ROOT/2.38.1" ] || { echo "current の版まで消した" >&2; return 1; }
  rm -rf "$BOOCH_AWS_CLI_ROOT" "$capdir"
}
# /proc を読めない（sudo の拒否など）ときは「使用中なし」と取り違えず、何も消さない（fail-closed）。
test_aws_cli_stale_fails_closed_when_proc_unreadable() {
  _aws_root aws-cli/2.38.1 2.37.0 2.38.1
  booch_aws_proc_exes() { :; }
  local out rc
  if out=$(booch_aws_cli_stale_versions sudo 2>/dev/null); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "" "$out"
  rm -rf "$BOOCH_AWS_CLI_ROOT"
}
# 読めないプロセスは find -printf '%l' で空行になる。空行しか無ければ読めていない。
test_aws_cli_stale_fails_closed_when_proc_gives_only_blank_lines() {
  _aws_root aws-cli/2.38.1 2.37.0 2.38.1
  booch_aws_proc_exes() { printf '\n\n\n'; }
  local rc; if booch_aws_cli_stale_versions sudo >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  rm -rf "$BOOCH_AWS_CLI_ROOT"
}
test_aws_cli_prune_removes_nothing_when_proc_unreadable() {
  _aws_root aws-cli/2.38.1 2.37.0 2.38.1
  booch_aws_proc_exes() { :; }
  sudo() { "$@"; }
  local rc; if booch_aws_cli_prune >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  [ -d "$BOOCH_AWS_CLI_ROOT/2.37.0" ] || { echo "使用中か判定できない版を消した" >&2; return 1; }
  rm -rf "$BOOCH_AWS_CLI_ROOT"
}
# current が壊れていれば、sudo の要る /proc の走査をしない。
test_aws_cli_stale_skips_proc_scan_when_current_is_broken() {
  _aws_root "" 2.37.0 2.38.1
  local capdir; capdir=$(mktemp -d)
  booch_aws_proc_exes() { : > "$capdir/scanned"; echo /usr/bin/bash; }
  booch_aws_cli_stale_versions sudo >/dev/null
  assert_file_absent "$capdir/scanned"
  rm -rf "$BOOCH_AWS_CLI_ROOT" "$capdir"
}
test_aws_cli_prune_noop_without_stale() {
  _aws_root aws-cli/2.38.1 2.38.1
  local called=0
  sudo() { called=1; }
  booch_aws_cli_prune >/dev/null
  assert_eq "0" "$called"
  rm -rf "$BOOCH_AWS_CLI_ROOT"
}
# find は読めないプロセスがあると非 0 で終わるが、読めた分を使い、set -e の下でも止まらない。
test_aws_proc_exes_tolerates_find_failure() {
  find() { echo /x/2.37.0/dist/aws; return 1; }
  local out rc
  if out=$(set -e; booch_aws_proc_exes); then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_eq "/x/2.37.0/dist/aws" "$out"
}

run_tests
