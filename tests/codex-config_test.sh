#!/usr/bin/env bash
# lib/codex.sh のユニットテスト。TOML トップレベルキーの読み取りと、~/.codex/config.toml への
# キー単位冪等同期を検証する（booch_set_toml_key に委譲。他キー・セクションを壊さない）。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/fs.sh
source "$BOOCH_ROOT/lib/fs.sh"
# shellcheck source=lib/codex-config.sh
source "$BOOCH_ROOT/lib/codex-config.sh"

# トップレベルの key=value だけを "key<TAB>value" で返す。コメント・空行は無視し、[section]
# 以降は対象外。値は TOML 表記のまま。
test_top_level_keys_reads_top_only() {
  local f; f=$(mktemp)
  printf '# comment\nmodel = "gpt-5.4"\n\nsandbox = "read-only"\n[tui]\ntheme = "x"\n' > "$f"
  assert_eq "$(printf 'model\t"gpt-5.4"\nsandbox\t"read-only"')" "$(booch_codex_config_top_level_keys "$f")"
  rm -f "$f"
}
test_top_level_keys_missing_file_empty() {
  assert_eq "" "$(booch_codex_config_top_level_keys /nonexistent/config.toml)"
}

# sync は source のトップレベルキーで dest を更新し、dest の他キー・セクションは温存する。
test_config_sync_updates_and_preserves() {
  local src dest; src=$(mktemp); dest=$(mktemp)
  printf 'model = "new"\n' > "$src"
  printf 'model = "old"\nkeep = 1\n[tui]\ntheme = "z"\n' > "$dest"
  booch_codex_config_sync "$src" "$dest"
  assert_eq 'model = "new"
keep = 1
[tui]
theme = "z"' "$(cat "$dest")"
  rm -f "$src" "$dest"
}

# source に無いキーは dest に足さない（source のトップレベルキーだけを反映）。
test_config_sync_only_source_keys() {
  local src dest; src=$(mktemp); dest=$(mktemp)
  printf 'a = 1\n' > "$src"
  printf 'b = 2\n' > "$dest"
  booch_codex_config_sync "$src" "$dest"
  assert_eq 'b = 2
a = 1' "$(cat "$dest")"
  rm -f "$src" "$dest"
}

# source が無ければ何もしない（dest を作らない・触らない）。
test_config_sync_missing_source_noop() {
  local dest; dest=$(mktemp); rm -f "$dest"
  booch_codex_config_sync /nonexistent/src.toml "$dest"
  assert_file_absent "$dest"
}

# dest の親ディレクトリが無ければ作る。
test_config_sync_creates_dest_dir() {
  local src d; src=$(mktemp); d=$(mktemp -d)
  printf 'model = "x"\n' > "$src"
  booch_codex_config_sync "$src" "$d/nested/config.toml"
  assert_eq 'model = "x"' "$(cat "$d/nested/config.toml")"
  rm -rf "$src" "$d"
}

run_tests
