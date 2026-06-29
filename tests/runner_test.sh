#!/usr/bin/env bash
# lib/runner.sh のユニットテスト。実ツール・ネットワーク不要（フェイク job で駆動）。
# code-review で潰したバグの回帰ガードを兼ねる。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/runner.sh
source "$BOOCH_ROOT/lib/runner.sh"

# --- フェイク job（名前は test_ で始めない＝テストとして拾われない） ---
_j_installed() { booch_result "tool-i" installed "" "1.0.0"; }
_j_updated()   { booch_result "tool-u" updated "1.0.0" "1.1.0"; }
_j_current()   { booch_result "tool-c" current "2.0.0"; }
_j_migrated()  { booch_result "tool-m" migrated "old" "new"; }
_j_fail()      { return 1; }
_j_slow()      { sleep 3; }
_j_pipe()      { false | true; booch_result "pipe" current "ran"; }

test_summary_renders_all_statuses() {
  booch_runner_init
  booch_job i "inst" _j_installed 60
  booch_job u "upd"  _j_updated   60
  booch_job c "cur"  _j_current   60
  booch_job m "mig"  _j_migrated  60
  local out
  out=$(booch_run)
  assert_contains "$out" "installed  1.0.0"
  assert_contains "$out" "updated    1.0.0 → 1.1.0"
  assert_contains "$out" "latest     2.0.0"
  assert_contains "$out" "migrated   old → new"
}

# 非 0 終了したジョブは自身では failed 行を書けない。_booch_exec が補う。
test_failed_job_appears_in_summary() {
  booch_runner_init
  booch_job f "failjob" _j_fail 60
  local out rc
  if out=$(booch_run); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "failjob"
  assert_contains "$out" "failed"
}

# timeout で kill されたジョブ（exit 124）も failed としてサマリーに出る。
test_timeout_kill_appears_in_summary() {
  booch_runner_init
  booch_job s "slowjob" _j_slow 1
  local out rc
  if out=$(booch_run); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "slowjob"
  assert_contains "$out" "failed"
}

# 回帰ガード: pipefail を持つ caller の下で、同一ジョブが timeout 指定の有無で
# 成否を変えてはならない（旧実装では非 timeout だけ caller の pipefail を継承し
# 分岐していた）。両方 success（rc 0）になるのが正。
test_timeout_consistency_under_pipefail() {
  set -o pipefail
  booch_runner_init
  booch_job a "with-to" _j_pipe 60
  booch_job b "no-to"   _j_pipe 0
  local out rc
  if out=$(booch_run); then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_contains "$out" "pipe"
  assert_contains "$out" "ran"
}

test_duplicate_job_name_rejected() {
  booch_runner_init
  booch_job x "X1" _j_current 60
  local rc
  if booch_job x "X2" _j_current 60 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# 未定義のジョブ関数は登録時に弾く（typo を実行時の不可解なエラーにしない）。
test_undefined_job_fn_rejected() {
  booch_runner_init
  local rc
  if booch_job y "Y" _j_does_not_exist 60 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# booch_version はルートの VERSION を読む（消費側が実行時に版を名乗れる）。
test_booch_version_reads_version_file() {
  assert_eq "$(cat "$BOOCH_ROOT/VERSION")" "$(booch_version)"
}

# ジョブ名のディレクトリ脱出・空名を拒否する（結果ファイルが結果ディレクトリ外へ
# 書き出されるのを防ぐ。Codex 監査指摘）。
test_job_name_rejects_path_escape() {
  booch_runner_init
  local rc
  if booch_job "../evil" "X" _j_current 60 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  if booch_job "a/b" "X" _j_current 60 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  if booch_job "" "X" _j_current 60 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# 非 tty 出力に色エスケープを混ぜない（パイプ/CI/ログ捕捉対策）。
test_no_color_when_not_tty() {
  booch_runner_init
  booch_job i "inst" _j_installed 60
  local out
  out=$(booch_run)
  assert_not_contains "$out" $'\033['
}

test_cleanup_removes_and_unsets_result_dir_on_success() {
  booch_runner_init
  local dir="$BOOCH_RESULT_DIR"
  booch_job i "inst" _j_installed 60
  booch_run >/dev/null
  assert_file_absent "$dir"
  assert_eq "" "${BOOCH_RESULT_DIR:-}" "BOOCH_RESULT_DIR unset after run"
}

test_concurrent_log_dir_unset_after_run() {
  booch_runner_init
  booch_job i "inst" _j_installed 60
  booch_run >/dev/null
  assert_eq "" "${CONCURRENT_LOG_DIR:-}" "CONCURRENT_LOG_DIR unset after run"
}

test_empty_jobs_path_cleans_up() {
  booch_runner_init
  local dir="$BOOCH_RESULT_DIR"
  local rc
  if booch_run >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_file_absent "$dir"
}

# caller の set -u を壊さない（concurrent 実行中だけ退避し、run 後に戻す）。
test_caller_set_u_restored() {
  set -u
  booch_runner_init
  booch_job i "inst" _j_installed 60
  booch_run >/dev/null
  case $- in
    *u*) : ;;
    *) fail "set -u が復元されていない" ;;
  esac
}

run_tests
