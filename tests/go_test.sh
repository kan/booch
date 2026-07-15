#!/usr/bin/env bash
# jobs/go.sh のユニットテスト。継ぎ目（booch_go_*）をスタブで差し替え、
# ネットワーク / sudo 無しで分岐を検証する。

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
# shellcheck source=lib/verify.sh
source "$BOOCH_ROOT/lib/verify.sh"
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

# --- booch_go_tools_ensure（BOOCH_GO_TOOLS の go install）。seam をスタブ ---
# BOOCH_GO_TOOLS 未設定なら何もしない（go.result が生まれない）。
test_go_tools_noop_when_unset() {
  booch_runner_init
  export BOOCH_JOB=go
  unset BOOCH_GO_TOOLS
  booch_go_tools_ensure
  assert_file_absent "$BOOCH_RESULT_DIR/go.result"
}

# 未導入のツールは installed、basename で記録する。
test_go_tools_installs_by_basename() {
  booch_runner_init
  export BOOCH_JOB=go
  export BOOCH_GO_TOOLS="github.com/justjanne/powerline-go"
  booch_go_tool_install() { :; }
  local _calls=0
  booch_go_tool_version() { _calls=$((_calls+1)); [ "$_calls" -le 1 ] && printf '' || printf 'v1.2.3'; }
  booch_go_tools_ensure
  assert_eq "powerline-go|installed||v1.2.3" "$(cat "$BOOCH_RESULT_DIR/go.result")"
  unset BOOCH_GO_TOOLS
}

# 版が変わると updated。
test_go_tools_updates_when_version_changes() {
  booch_runner_init
  export BOOCH_JOB=go
  export BOOCH_GO_TOOLS="golang.org/x/tools/gopls"
  booch_go_tool_install() { :; }
  local _calls=0
  booch_go_tool_version() { _calls=$((_calls+1)); [ "$_calls" -le 1 ] && printf 'v0.1.0' || printf 'v0.2.0'; }
  booch_go_tools_ensure
  assert_eq "gopls|updated|v0.1.0|v0.2.0" "$(cat "$BOOCH_RESULT_DIR/go.result")"
  unset BOOCH_GO_TOOLS
}

# install 失敗は continue（結果行を残さない）。
test_go_tools_install_failure_skips_row() {
  booch_runner_init
  export BOOCH_JOB=go
  export BOOCH_GO_TOOLS="example.com/broken/tool"
  booch_go_tool_install() { return 1; }
  booch_go_tool_version() { printf ''; }
  booch_go_tools_ensure 2>/dev/null
  assert_file_absent "$BOOCH_RESULT_DIR/go.result"
  unset BOOCH_GO_TOOLS
}

# 複数モジュールはそれぞれ行を追記する。
test_go_tools_multiple_modules() {
  booch_runner_init
  export BOOCH_JOB=go
  export BOOCH_GO_TOOLS="github.com/justjanne/powerline-go golang.org/x/tools/gopls"
  booch_go_tool_install() { :; }
  booch_go_tool_version() { printf 'v9.9.9'; }   # 既存と同版 → current
  booch_go_tools_ensure
  local out; out=$(cat "$BOOCH_RESULT_DIR/go.result")
  assert_contains "$out" "powerline-go|current"
  assert_contains "$out" "gopls|current"
  unset BOOCH_GO_TOOLS
}

# --- booch_go_install の SHA256 検証（curl/sudo をスタブし network/sudo 無しで） ---
# 期待ハッシュと取得物が食い違えば、展開（tar）/ sudo の入替へ進む前に失敗する。
# curl は -o 先（最終引数）へ偽 tarball を書き、sudo は no-op（RETURN trap の掃除も無害化）。
# stub は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317,SC2329
test_go_install_aborts_on_checksum_mismatch() {
  uname() { echo x86_64; }
  curl() { local out; for out; do :; done; printf 'fake' > "$out"; }
  sudo() { return 0; }
  booch_go_expected_sha256() { printf '%s' 1111111111111111111111111111111111111111111111111111111111111111; }
  local out rc; if out=$(booch_go_install go1.99.0 2>&1); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  # sudo の入替へ進む前に verify が原因で止まったことを断定する（検証配線の回帰ガード）。
  assert_contains "$out" "SHA256 検証に失敗"
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
# shellcheck disable=SC2317,SC2329
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
# shellcheck disable=SC2317,SC2329
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
