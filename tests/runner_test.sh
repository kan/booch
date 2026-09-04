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
_j_result_ver() {
  booch_result_ver "ver-new"  ""      "1.0.0"
  booch_result_ver "ver-up"   "1.0.0" "1.1.0"
  booch_result_ver "ver-same" "2.0.0" "2.0.0"
}
# ジョブ全体は成功のまま、内訳の 1 件だけを failed として理由付きで報告する
# （marketplace 1 個の更新失敗でジョブごと落とさない、という利用側のパターン）。
_j_part_failed() {
  booch_result "part-ok" current "1.0.0"
  booch_result_failed "part-ng" "更新できません: acme"
}
_j_failed_noreason() { booch_result "part-z" failed; }
# 区切り文字と改行を含む理由。サマリー行が壊れないこと（潰されること）を見る。
_j_dirty_reason() { booch_result_failed "part-d" $'壊れた|理由\n2 行目'; }
# 理由付き failed 行が、同じジョブの版付き行の表示を壊さないこと。
_j_ver_and_reason() {
  booch_result "ver-keep" updated "1.0.0" "1.1.0"
  booch_result_failed "ver-ng" "理由だけ"
}

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

# 導入前後の版から status を決める（版が変われば updated として old → new を残す）。
test_result_ver_maps_versions_to_status() {
  booch_runner_init
  booch_job v "ver" _j_result_ver 60
  local out
  out=$(booch_run)
  assert_contains "$out" "ver-new"
  assert_contains "$out" "installed  1.0.0"
  assert_contains "$out" "updated    1.0.0 → 1.1.0"
  assert_contains "$out" "latest     2.0.0"
}

# ジョブが自分で書く failed 行は理由を伴える（ジョブ自体は成功のまま内訳だけ落とす用途）。
# 理由が出ないと「何が失敗したか」がサマリーから分からず、ジョブが成功扱いのため
# bash-concurrent のログ表示にも載らない（＝失敗が完全に見えなくなる）。
test_failed_result_shows_reason() {
  booch_runner_init
  booch_job p "part" _j_part_failed 60
  local out
  out=$(booch_run)
  assert_contains "$out" "part-ok"
  assert_contains "$out" "failed     更新できません: acme"
}

# 理由なしの呼び出し（従来の 2 引数。_booch_exec が書く行も同じ）は余計な余白を足さない。
test_failed_result_without_reason_has_no_trailing_space() {
  booch_runner_init
  booch_job z "noreason" _j_failed_noreason 60
  local out
  out=$(booch_run)
  assert_contains "$out" "part-z"
  assert_not_contains "$out" "failed  "
}

# 理由付き failed 行を混ぜても、版を持つ行の表示は変わらない。
test_reason_does_not_disturb_version_rows() {
  booch_runner_init
  booch_job vr "verreason" _j_ver_and_reason 60
  local out
  out=$(booch_run)
  assert_contains "$out" "updated    1.0.0 → 1.1.0"
  assert_contains "$out" "failed     理由だけ"
}

# 理由に区切り文字（|）や改行が混ざってもサマリー行は 1 行のまま壊れない。
test_failed_result_reason_is_sanitized() {
  booch_runner_init
  booch_job d "dirty" _j_dirty_reason 60
  local out
  out=$(booch_run)
  assert_contains "$out" "failed     壊れた 理由 2 行目"
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

# 回帰ガード: declare -f の総量が 1 引数上限（MAX_ARG_STRLEN = 32×ページ = 128KiB）を
# 超えてもジョブが実行できる。旧実装は inner を `bash -c "$inner"` の単一引数で渡していた
# ため、booch の lib/jobs が増えて declare -f が 128KiB に達すると execve が E2BIG
# （timeout: Argument list too long）で全ジョブ失敗した。inner を一時ファイル経由で
# 実行することで引数長上限を回避する。
test_large_function_corpus_runs() {
  # declare -f 出力が 128KiB を確実に超えるよう、巨大リテラルを抱えた関数を定義する
  # （declare -f はコメントを落とすが、文字列リテラルは保持するため inner が膨らむ）。
  local blob
  blob=$(head -c 160000 /dev/zero | tr '\0' 'x')
  eval "_j_huge() { local _pad='$blob'; : \"\${#_pad}\"; booch_result huge current ok; }"
  booch_runner_init
  booch_job h "hugejob" _j_huge 60
  local out rc
  if out=$(booch_run); then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_contains "$out" "hugejob"
  assert_contains "$out" "latest     ok"
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
