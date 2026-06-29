#!/usr/bin/env bash
# jobs/delta.sh のユニットテスト。seam をスタブで差し替え、分岐・資産名・arch を検証する。

# dpkg() を上書きするのは booch_delta_arch（bare dpkg）の検証のため。delta.sh 内の
# `sudo dpkg` には効かないが、テストでは booch_delta_install をスタブするので実行
# されない。SC2032（sudo 経由では関数が使われない）は本テストでは無害なので抑制する。
# shellcheck disable=SC2032

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/runner.sh
source "$BOOCH_ROOT/lib/runner.sh"
# shellcheck source=lib/github.sh
source "$BOOCH_ROOT/lib/github.sh"
# shellcheck source=jobs/delta.sh
source "$BOOCH_ROOT/jobs/delta.sh"

# --- 純粋関数 / arch ---
test_delta_asset_name() {
  assert_eq "git-delta-musl_0.18.2_amd64.deb" "$(booch_delta_asset 0.18.2 amd64)"
}
test_delta_arch_amd64() {
  dpkg() { echo amd64; }
  assert_eq "amd64" "$(booch_delta_arch)"
}
test_delta_arch_unsupported_fails() {
  dpkg() { echo riscv64; }
  local rc; if booch_delta_arch >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- job_delta 分岐（実処理はスタブ） ---
_run_job_delta() { # installed latest
  booch_runner_init
  local _inst=$1 _lat=$2
  booch_delta_arch() { echo amd64; }
  booch_delta_installed_version() { printf '%s' "$_inst"; }
  booch_delta_latest() { printf '%s' "$_lat"; }
  booch_delta_install() { :; }
  export BOOCH_JOB=delta
  job_delta
}

test_delta_installs_when_missing() {
  _run_job_delta "" "0.18.2"
  assert_eq "delta|installed||0.18.2" "$(cat "$BOOCH_RESULT_DIR/delta.result")"
}
test_delta_updates_when_differ() {
  _run_job_delta "0.18.1" "0.18.2"
  assert_eq "delta|updated|0.18.1|0.18.2" "$(cat "$BOOCH_RESULT_DIR/delta.result")"
}
test_delta_current_when_equal() {
  _run_job_delta "0.18.2" "0.18.2"
  assert_eq "delta|current|0.18.2|" "$(cat "$BOOCH_RESULT_DIR/delta.result")"
}
# v 付きタグでも同一バージョンなら current（永久更新ループに陥らない）。
test_delta_current_when_tag_has_v_prefix() {
  _run_job_delta "0.18.2" "v0.18.2"
  assert_eq "delta|current|0.18.2|" "$(cat "$BOOCH_RESULT_DIR/delta.result")"
}

test_delta_fails_when_latest_unavailable() {
  booch_runner_init
  booch_delta_arch() { echo amd64; }
  booch_delta_installed_version() { printf '0.18.1'; }
  booch_delta_latest() { return 1; }
  booch_delta_install() { :; }
  export BOOCH_JOB=delta
  local rc; if job_delta >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$BOOCH_RESULT_DIR/delta.result"
}

test_delta_fails_when_arch_unsupported() {
  booch_runner_init
  booch_delta_arch() { return 1; }
  export BOOCH_JOB=delta
  local rc; if job_delta >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# install が download に渡す資産名が正しいことを検証する（dpkg/sudo に到達しないよう
# download スタブは捕捉して非 0 を返す）。捕捉変数は install のローカルと衝突しない名前。
test_delta_install_passes_correct_asset() {
  local cap_repo="" cap_asset=""
  booch_github_download_asset() { cap_repo=$1; cap_asset=$3; return 1; }
  local rc; if booch_delta_install 0.18.2 amd64; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "dandavison/delta" "$cap_repo"
  assert_eq "git-delta-musl_0.18.2_amd64.deb" "$cap_asset"
}

# 競合する動的版 git-delta が入っているときだけ purge してから musl .deb を入れる。
# download/dpkg/sudo をスタブし、purge の発火条件を回帰ガードする（実 sudo 不要）。
# shellcheck disable=SC2317  # スタブは install 内からのみ呼ばれる
test_delta_install_purges_conflicting_dynamic_pkg() {
  booch_github_download_asset() { : > "$4"; }     # DL 成功（空 .deb を作る）
  dpkg() { [ "$1" = "-s" ] && return 0; return 0; }   # git-delta は導入済み
  local cap=""; sudo() { cap="$cap|$*"; return 0; }
  booch_delta_install 0.19.2 amd64 >/dev/null 2>&1
  assert_contains "$cap" "dpkg -P git-delta"
  assert_contains "$cap" "dpkg -i"
}
# 動的版が入っていなければ purge せず、そのまま musl .deb を入れる。
# shellcheck disable=SC2317
test_delta_install_skips_purge_when_absent() {
  booch_github_download_asset() { : > "$4"; }
  dpkg() { [ "$1" = "-s" ] && return 1; return 0; }   # git-delta 未導入
  local cap=""; sudo() { cap="$cap|$*"; return 0; }
  booch_delta_install 0.19.2 amd64 >/dev/null 2>&1
  assert_not_contains "$cap" "dpkg -P"
  assert_contains "$cap" "dpkg -i"
}

# --- runner 経由（declare -f でスタブが子へ運ばれること＋失敗時の自動 failed 記録） ---
# shellcheck disable=SC2317  # スタブは runner の bash -c 子経由でのみ呼ばれる
test_delta_via_runner_reports_installed() {
  booch_runner_init
  booch_delta_arch() { echo amd64; }
  booch_delta_installed_version() { printf ''; }
  booch_delta_latest() { printf '0.18.2'; }
  booch_delta_install() { :; }
  booch_job delta "delta" job_delta 60
  local out; out=$(booch_run)
  assert_contains "$out" "delta"
  assert_contains "$out" "installed"
}

# install 失敗時、job は booch_result 到達前に abort し runner が failed を補う。
# shellcheck disable=SC2317
test_delta_via_runner_install_failure_is_failed() {
  booch_runner_init
  booch_delta_arch() { echo amd64; }
  booch_delta_installed_version() { printf ''; }
  booch_delta_latest() { printf '0.18.2'; }
  booch_delta_install() { return 1; }
  booch_job delta "delta" job_delta 60
  local out rc; if out=$(booch_run); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "failed"
}

run_tests
