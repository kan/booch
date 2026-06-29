#!/usr/bin/env bash
# lib/scaffold.sh のユニットテスト。生成結果（ファイル一式・冪等性・生成物の構文・
# プレースホルダ）を回帰ガードする。network / sudo 不要。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/scaffold.sh
source "$BOOCH_ROOT/lib/scaffold.sh"

_scaffold_into() { local d; d=$(mktemp -d); booch_scaffold "$d" >/dev/null; printf '%s' "$d"; }

test_scaffold_creates_expected_files() {
  local d f; d=$(_scaffold_into)
  for f in bootstrap.sh jobs/example.sh config/README.md .gitignore README.md; do
    [ -f "$d/$f" ] || fail "missing: $f"
  done
  rm -rf "$d"
}

# 生成したシェルスクリプトは構文的に妥当（雛形が壊れていないことの最低保証）。
test_scaffold_generated_scripts_are_valid_bash() {
  local d; d=$(_scaffold_into)
  bash -n "$d/bootstrap.sh" || fail "bootstrap.sh が構文エラー"
  bash -n "$d/jobs/example.sh" || fail "example.sh が構文エラー"
  rm -rf "$d"
}

# bootstrap.sh は実行可能ビットが立つ。
test_scaffold_bootstrap_is_executable() {
  local d; d=$(_scaffold_into)
  [ -x "$d/bootstrap.sh" ] || fail "bootstrap.sh が実行可能でない"
  rm -rf "$d"
}

# 再実行で既存ファイルを上書きしない（編集が保たれる・skip を表示）。
test_scaffold_is_idempotent_and_preserves_edits() {
  local d out; d=$(mktemp -d)
  booch_scaffold "$d" >/dev/null
  echo "MYEDIT" >> "$d/README.md"
  out=$(booch_scaffold "$d")
  assert_contains "$out" "skip（既存）"
  assert_contains "$(cat "$d/README.md")" "MYEDIT"
  rm -rf "$d"
}

# 生成先未指定は失敗する。
test_scaffold_requires_dir_arg() {
  local rc
  if booch_scaffold "" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# 個人固有・業務固有の値を埋め込まず、推奨構成（submodule）とプレースホルダで示す。
test_scaffold_uses_placeholders_not_personal_values() {
  local d; d=$(_scaffold_into)
  assert_contains "$(cat "$d/bootstrap.sh")" "vendor/booch"
  assert_contains "$(cat "$d/jobs/example.sh")" "(edit me)"
  rm -rf "$d"
}

run_tests
