#!/usr/bin/env bash
# lib/npm.sh のユニットテスト。npm 実行（booch_npm_run）をスタブし、ローカル同期と
# グローバル install の挙動を検証する（実 npm 不要）。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/npm.sh
source "$BOOCH_ROOT/lib/npm.sh"

test_npm_local_install_fails_without_package_json() {
  local src; src=$(mktemp -d)
  local dest; dest=$(mktemp -d)
  local rc; if booch_npm_local_install "$src" "$dest" 2>/dev/null; then rc=0; else rc=$?; fi
  rm -rf "$src" "$dest"
  assert_status 1 "$rc"
}

test_npm_local_install_copies_manifest_and_installs() {
  local src; src=$(mktemp -d)
  local dest; dest=$(mktemp -d)
  printf '{"name":"x"}' > "$src/package.json"
  printf '{}' > "$src/package-lock.json"
  # local_install は npm を ( cd dest && ... ) のサブシェルで呼ぶため、捕捉は
  # 変数でなく temp ファイルへ（サブシェルの変数代入は親へ伝わらない）。
  local capfile; capfile=$(mktemp)
  booch_npm_run() { echo "$*" >> "$capfile"; }
  booch_npm_local_install "$src" "$dest"
  local cap; cap=$(cat "$capfile")
  assert_eq "installed-pkg" "$([ -f "$dest/package.json" ] && echo installed-pkg)" "package.json をコピー"
  assert_eq "installed-lock" "$([ -f "$dest/package-lock.json" ] && echo installed-lock)" "lock をコピー"
  assert_contains "$cap" "install --no-audit --no-fund"
  rm -rf "$src" "$dest" "$capfile"
}

test_npm_local_install_without_lock() {
  local src; src=$(mktemp -d)
  local dest; dest=$(mktemp -d)
  printf '{"name":"x"}' > "$src/package.json"
  booch_npm_run() { :; }
  local rc; if booch_npm_local_install "$src" "$dest"; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_file_absent "$dest/package-lock.json"
  rm -rf "$src" "$dest"
}

# npm install の失敗が関数の rc に伝播する（サブシェル最後の文の rc）。
test_npm_local_install_propagates_npm_failure() {
  local src; src=$(mktemp -d)
  local dest; dest=$(mktemp -d)
  printf '{"name":"x"}' > "$src/package.json"
  booch_npm_run() { return 1; }
  local rc; if booch_npm_local_install "$src" "$dest"; then rc=0; else rc=$?; fi
  rm -rf "$src" "$dest"
  assert_status 1 "$rc"
}

# 空白入りパスでも壊れない（クォート確認）。
test_npm_local_install_handles_spaces_in_paths() {
  local src; src=$(mktemp -d)
  local base; base=$(mktemp -d); local dest="$base/with space"
  printf '{"name":"x"}' > "$src/package.json"
  booch_npm_run() { :; }
  booch_npm_local_install "$src" "$dest"
  local ok=""; [ -f "$dest/package.json" ] && ok=yes
  rm -rf "$src" "$base"
  assert_eq "yes" "$ok" "空白入り dest にもコピーできる"
}

test_npm_global_ensure_uses_prefix() {
  BOOCH_NPM_PREFIX="/tmp/booch-npm-prefix"
  local cap=""
  booch_npm_run() { cap="$*"; }
  booch_npm_global_ensure typescript-language-server typescript
  assert_eq "install -g --prefix /tmp/booch-npm-prefix typescript-language-server typescript" "$cap"
}

run_tests
