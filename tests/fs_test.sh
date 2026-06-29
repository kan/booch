#!/usr/bin/env bash
# lib/fs.sh のユニットテスト。temp ディレクトリ上で symlink / toml キーを検証する。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/fs.sh
source "$BOOCH_ROOT/lib/fs.sh"

# --- booch_symlink ---
test_symlink_creates_when_absent() {
  local d; d=$(mktemp -d)
  : > "$d/src"
  booch_symlink "$d/src" "$d/dest" >/dev/null
  assert_eq "$d/src" "$(readlink "$d/dest")"
  rm -rf "$d"
}

test_symlink_creates_parent_dir() {
  local d; d=$(mktemp -d)
  : > "$d/src"
  booch_symlink "$d/src" "$d/deep/nested/dest" >/dev/null
  assert_eq "$d/src" "$(readlink "$d/deep/nested/dest")"
  rm -rf "$d"
}

test_symlink_updates_when_target_differs() {
  local d; d=$(mktemp -d)
  : > "$d/a"; : > "$d/b"; ln -s "$d/a" "$d/dest"
  booch_symlink "$d/b" "$d/dest" >/dev/null
  assert_eq "$d/b" "$(readlink "$d/dest")"
  rm -rf "$d"
}

test_symlink_skips_when_target_same() {
  local d; d=$(mktemp -d)
  : > "$d/a"; ln -s "$d/a" "$d/dest"
  local out; out=$(booch_symlink "$d/a" "$d/dest")
  assert_contains "$out" "symlink 済み"
  assert_eq "$d/a" "$(readlink "$d/dest")"
  rm -rf "$d"
}

# 実体ファイルがあるときは .bak へ退避してから symlink を張る。
test_symlink_backs_up_real_file() {
  local d; d=$(mktemp -d)
  : > "$d/src"; printf 'real-content' > "$d/dest"
  booch_symlink "$d/src" "$d/dest" >/dev/null 2>&1
  assert_eq "real-content" "$(cat "$d/dest.bak")"
  assert_eq "$d/src" "$(readlink "$d/dest")"
  rm -rf "$d"
}

# 既に .bak があるときは上書きせず、最初のバックアップを保持する（別名へ退避）。
test_symlink_preserves_existing_bak() {
  local d; d=$(mktemp -d)
  : > "$d/src"
  printf 'first-backup' > "$d/dest.bak"   # 既存の重要なバックアップ
  printf 'real-content' > "$d/dest"
  booch_symlink "$d/src" "$d/dest" >/dev/null 2>&1
  assert_eq "first-backup" "$(cat "$d/dest.bak")" "既存 .bak を壊さない"
  assert_eq "$d/src" "$(readlink "$d/dest")"
  rm -rf "$d"
}

# --- booch_set_toml_key ---
test_toml_adds_when_absent() {
  local f; f=$(mktemp)
  booch_set_toml_key "$f" model '"gpt-5.4"'
  assert_eq 'model = "gpt-5.4"' "$(cat "$f")"
  rm -f "$f"
}

test_toml_updates_when_present() {
  local f; f=$(mktemp)
  printf 'model = "old"\n' > "$f"
  booch_set_toml_key "$f" model '"new"'
  assert_eq 'model = "new"' "$(cat "$f")"
  rm -f "$f"
}

# 他キーには触れない（前後の行を保つ）。
test_toml_preserves_other_keys() {
  local f; f=$(mktemp)
  printf 'a = 1\nmodel = "old"\nb = 2\n' > "$f"
  booch_set_toml_key "$f" model '"new"'
  local content; content=$(cat "$f")
  assert_contains "$content" 'a = 1'
  assert_contains "$content" 'model = "new"'
  assert_contains "$content" 'b = 2'
  rm -f "$f"
}

# キー名前後の空白の有無に関わらず一致して置換する。
test_toml_matches_spaced_key() {
  local f; f=$(mktemp)
  printf 'model="old"\n' > "$f"
  booch_set_toml_key "$f" model '"new"'
  assert_eq 'model = "new"' "$(cat "$f")"
  rm -f "$f"
}

# 親ディレクトリが無くても作って配置する（~/.codex/config.toml 初回相当）。
test_toml_creates_parent_dir() {
  local d; d=$(mktemp -d)
  booch_set_toml_key "$d/nested/config.toml" model '"x"'
  assert_eq 'model = "x"' "$(cat "$d/nested/config.toml")"
  rm -rf "$d"
}

# 置換メタ文字（& | \ /）を含む値もリテラルに書き込む（sed 誤置換の回帰ガード）。
test_toml_value_with_metacharacters_is_literal() {
  local f; f=$(mktemp)
  booch_set_toml_key "$f" url '"a&b|c\d/e"'
  booch_set_toml_key "$f" url '"x&y|z"'   # 既存キーを再置換しても壊れない
  assert_eq 'url = "x&y|z"' "$(cat "$f")"
  rm -f "$f"
}

# regex メタ文字を含むキーはリテラル一致（'a.b' が 'aXb' 行を誤置換しない）。
test_toml_dotted_key_is_literal_match() {
  local f; f=$(mktemp)
  printf 'aXb = 1\n' > "$f"
  booch_set_toml_key "$f" 'a.b' '2'
  local content; content=$(cat "$f")
  assert_contains "$content" 'aXb = 1'      # 別行は触らない
  assert_contains "$content" 'a.b = 2'      # 新規追記
  rm -f "$f"
}

run_tests
