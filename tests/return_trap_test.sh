#!/usr/bin/env bash
# RETURN トラップ漏れの回帰テスト。
#
# install 系の各関数は temp 掃除に `trap '... ' RETURN` を使う。RETURN トラップは関数
# return 後も解除されず呼び出し元のスコープに残り、呼び出し元の return 時に再発火する。
# 再発火時には内側関数のローカル変数（tmp / stage / deb）が既に消えており、呼び出し元が
# set -u だと「未割り当て変数」で落ちる（利用側 dotfiles は set -uo pipefail で走る）。
#
# 各関数を「set -u 下で `func ... || true; return 0` の呼び出し元」から駆動し、呼び出し元
# return が落ちずに最後まで到達できる（番兵 DONE が出る）ことを確認する。ネットワーク /
# sudo / 展開は seam・コマンドをスタブで差し替え、mktemp のみ実体で動かす。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/apt.sh
source "$BOOCH_ROOT/lib/apt.sh"
# shellcheck source=lib/uv.sh
source "$BOOCH_ROOT/lib/uv.sh"
# shellcheck source=lib/claude.sh
source "$BOOCH_ROOT/lib/claude.sh"
# shellcheck source=jobs/go.sh
source "$BOOCH_ROOT/jobs/go.sh"
# shellcheck source=jobs/delta.sh
source "$BOOCH_ROOT/jobs/delta.sh"
# shellcheck source=jobs/codex.sh
source "$BOOCH_ROOT/jobs/codex.sh"
# shellcheck source=jobs/aws.sh
source "$BOOCH_ROOT/jobs/aws.sh"
# shellcheck source=jobs/circleci.sh
source "$BOOCH_ROOT/jobs/circleci.sh"

# ネットワーク / sudo / 展開を潰すスタブ群を、呼び出した（サブ）シェルに定義する。
# 個々の install 関数が間接的に呼ぶだけなので shellcheck からは到達不能に見える（SC2317）。
# tar / dpkg は対象コード内で `sudo tar` 等として呼ばれる箇所もあるが、sudo 自体もスタブで
# 潰しているため shell 関数として効かなくても問題ない（SC2032/SC2033 を抑止）。各スタブは
# source 済みの install 関数からコマンド名・seam 名として間接的に呼ばれるだけなので、
# 静的解析からは「未呼び出し」に見える（SC2329 を抑止。CI の 0.9.0 は出さないが差分
# 解析は新版で出すため）。
# shellcheck disable=SC2317,SC2032,SC2033,SC2329
_rt_stubs() {
  # -o で指定された先に空ファイルを置くだけ（実通信しない）。
  curl() { local o=""; while [ "$#" -gt 0 ]; do [ "$1" = -o ] && { o=$2; shift; }; shift; done; [ -n "$o" ] && : > "$o" 2>/dev/null; return 0; }
  sudo() { return 0; }   # 実コマンドを走らせない（/usr/local 等を触らない）
  tar() { return 0; }
  unzip() { return 0; }
  sh() { return 0; }
  bash() { return 0; }
  dpkg() { return 1; }   # 既存パッケージ無し扱い
  booch_github_download_asset() { return 0; }
  booch_verify_sha256() { return 0; }
  booch_verify_pick() { :; }
  booch_go_arch() { printf amd64; }
  booch_go_expected_sha256() { printf deadbeef; }
}

# func + args を「set -u 下の呼び出し元 return」から駆動し、落ちずに DONE まで到達するか。
# 漏れがあると呼び出し元 return（_rt_outer の return 0）で set -u が落ち、DONE は出ない。
_rt_no_leak() { # func args...
  (
    set -uo pipefail
    _rt_stubs
    _rt_outer() { "$@" >/dev/null 2>&1 || true; return 0; }
    _rt_outer "$@"
    printf DONE
  )
}

test_return_trap_no_leak_apt_install_key() {
  assert_eq DONE "$(_rt_no_leak booch_apt_install_key https://x /tmp/booch-rt-kr raw)"
}
test_return_trap_no_leak_uv_bootstrap_install() {
  assert_eq DONE "$(_rt_no_leak booch_uv_bootstrap_install)"
}
test_return_trap_no_leak_claude_install_script() {
  assert_eq DONE "$(_rt_no_leak booch_claude_install_script)"
}
test_return_trap_no_leak_go_install() {
  assert_eq DONE "$(_rt_no_leak booch_go_install go1.22.0)"
}
test_return_trap_no_leak_delta_install() {
  assert_eq DONE "$(_rt_no_leak booch_delta_install 0.18.2 amd64)"
}
test_return_trap_no_leak_codex_install() {
  assert_eq DONE "$(_rt_no_leak booch_codex_install rust-v0.1.0 x86_64)"
}
test_return_trap_no_leak_aws_cli_install() {
  assert_eq DONE "$(_rt_no_leak booch_aws_cli_install x86_64)"
}
test_return_trap_no_leak_aws_ssm_install() {
  assert_eq DONE "$(_rt_no_leak booch_aws_ssm_install x86_64)"
}
test_return_trap_no_leak_circleci_install() {
  assert_eq DONE "$(_rt_no_leak booch_circleci_install v0.1.0 amd64)"
}

run_tests
