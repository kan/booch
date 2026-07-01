#!/usr/bin/env bash
# lib/apidoc.sh のユニットテスト。抽出（ヘッダ / 1 行説明 / 関数シグネチャ）は
# fixture ファイルで純粋に検証し、解決 / 索引 / 詳細は実モジュール（lib/jobs）で見る。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/apidoc.sh
source "$BOOCH_ROOT/lib/apidoc.sh"

# --- fixture（抽出の期待を固定するための最小サンプル） ---
FIX_DIR="$(mktemp -d)"
trap 'rm -rf "$FIX_DIR"' EXIT

FIX="$FIX_DIR/sample.sh"
cat > "$FIX" <<'SAMPLE'
#!/usr/bin/env bash
# サンプル: 1 行目の説明。
# 2 行目の続き。
#
# 使い方の例。

booch_pub_one() { # a b [c]
  :
}
booch_pub_two() {
  :
}
_booch_internal() { :; }
job_sample() { :; }
SAMPLE

# --- ヘッダ抽出 ---
test_header_skips_shebang_and_strips_hash() {
  local out; out=$(booch_apidoc_header "$FIX")
  assert_contains "$out" "サンプル: 1 行目の説明。"
  assert_contains "$out" "2 行目の続き。"
  assert_contains "$out" "使い方の例。"
  assert_not_contains "$out" "#!/usr/bin/env bash"
  assert_not_contains "$out" "# サンプル"   # 先頭の "# " は外れている
}
# ヘッダは最初の非コメント行で打ち切る（本体のコードを取り込まない）。
test_header_stops_at_first_code_line() {
  local out; out=$(booch_apidoc_header "$FIX")
  assert_not_contains "$out" "booch_pub_one"
}

# --- 1 行説明 ---
test_summary_is_first_nonempty_header_line() {
  assert_eq "サンプル: 1 行目の説明。" "$(booch_apidoc_summary "$FIX")"
}

# --- 関数シグネチャ抽出 ---
test_functions_render_hint_as_args() {
  local out; out=$(booch_apidoc_functions "$FIX")
  assert_contains "$out" "booch_pub_one(a b [c])"
}
test_functions_render_no_hint_as_empty_parens() {
  local out; out=$(booch_apidoc_functions "$FIX")
  assert_contains "$out" "booch_pub_two()"
}
test_functions_include_job_entry() {
  local out; out=$(booch_apidoc_functions "$FIX")
  assert_contains "$out" "job_sample()"
}
# 内部関数（_booch_*）は公開扱いしない。
test_functions_exclude_internal() {
  local out; out=$(booch_apidoc_functions "$FIX")
  assert_not_contains "$out" "_booch_internal"
}

# --- 解決（lib → jobs、未知は非 0） ---
test_resolve_finds_lib() {
  assert_eq "$BOOCH_ROOT/lib/fs.sh" "$(booch_apidoc_resolve fs)"
}
test_resolve_finds_job() {
  assert_eq "$BOOCH_ROOT/jobs/go.sh" "$(booch_apidoc_resolve go)"
}
test_resolve_unknown_returns_1() {
  local rc; if booch_apidoc_resolve zzz_nope >/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- 索引（実モジュールを走査） ---
test_index_lists_lib_and_jobs_sections() {
  local out; out=$(booch_apidoc_index)
  assert_contains "$out" "ライブラリ (lib/):"
  assert_contains "$out" "提供ジョブ (jobs/):"
  assert_contains "$out" "doctor"
  assert_contains "$out" "go"
}

# --- 詳細表示 ---
test_show_real_module_has_header_and_functions() {
  local out; out=$(booch_apidoc_show fs)
  assert_contains "$out" "== fs (lib/fs.sh) =="
  assert_contains "$out" "公開関数:"
  assert_contains "$out" "booch_symlink("
}
test_show_unknown_returns_1_and_diagnoses() {
  local out rc
  if out=$(booch_apidoc_show zzz_nope 2>&1); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "不明なモジュール"
}
# 引数なしの show は索引にフォールバックする（bin/booch help の無引数と同じ挙動）。
test_show_without_name_falls_back_to_index() {
  local out; out=$(booch_apidoc_show)
  assert_contains "$out" "モジュール一覧"
}

run_tests
