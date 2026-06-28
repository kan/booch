#!/usr/bin/env bash
# lib/github.sh のユニットテスト。API/DL を seam で差し替え、JSON 解析と URL 組み立てを
# network 無しで検証する（jq の解析は実物を使う＝CI/ローカルとも jq 前提）。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/github.sh
source "$BOOCH_ROOT/lib/github.sh"

# --- booch_github_latest_tag ---
test_github_latest_tag_parses_tag() {
  booch_github_api() { printf '{"tag_name":"v1.2.3"}'; }
  assert_eq "v1.2.3" "$(booch_github_latest_tag owner/repo)"
}

test_github_latest_tag_keeps_rust_v_prefix() {
  booch_github_api() { printf '{"tag_name":"rust-v0.20.0"}'; }
  assert_eq "rust-v0.20.0" "$(booch_github_latest_tag openai/codex)"
}

test_github_latest_tag_fails_when_no_tag_field() {
  booch_github_api() { printf '{"message":"Not Found"}'; }
  local rc
  if booch_github_latest_tag owner/repo >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

test_github_latest_tag_fails_when_tag_null() {
  booch_github_api() { printf '{"tag_name":null}'; }
  local rc
  if booch_github_latest_tag owner/repo >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# API が空（curl 失敗等）でも jq の診断を出さず非 0 で返る。
test_github_latest_tag_fails_on_empty_api() {
  booch_github_api() { printf ''; }
  local out rc
  if out=$(booch_github_latest_tag owner/repo 2>/dev/null); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# 非 JSON（レート制限 HTML 等）で jq がエラー終了しても、診断を出して 1 を返す
# （set -e 下の bare 呼び出しで中断しない＝`|| tag=""` の回帰ガード）。
test_github_latest_tag_fails_on_non_json() {
  booch_github_api() { printf '<html>rate limited</html>'; }
  local err rc
  if err=$(booch_github_latest_tag owner/repo 2>&1 >/dev/null); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$err" "失敗"
}

# stdout はタグのみ（末尾改行で汚さない）。番兵連結で検出。
test_github_latest_tag_stdout_no_trailing_newline() {
  booch_github_api() { printf '{"tag_name":"v1.2.3"}'; }
  local out
  out=$(booch_github_latest_tag owner/repo; printf END)
  assert_eq "v1.2.3END" "$out"
}

# --- booch_github_download_asset（URL 組み立て） ---
test_github_download_asset_builds_release_url() {
  # 捕捉変数は download_asset のローカル（repo/tag/asset/dest）と衝突しない名前にする
  # （bash は動的スコープのため、同名だと stub の代入が関数側ローカルに入ってしまう）。
  local cap_url="" cap_dest=""
  booch_github_fetch() { cap_url=$1; cap_dest=$2; }
  booch_github_download_asset dandavison/delta v0.18.2 "git-delta_0.18.2_amd64.deb" /tmp/out.deb
  assert_eq "https://github.com/dandavison/delta/releases/download/v0.18.2/git-delta_0.18.2_amd64.deb" "$cap_url"
  assert_eq "/tmp/out.deb" "$cap_dest"
}

# fetch の失敗（非 0）が download_asset まで伝播する。
test_github_download_asset_propagates_fetch_failure() {
  booch_github_fetch() { return 1; }
  local rc
  if booch_github_download_asset o/r v1 a /tmp/x; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

run_tests
