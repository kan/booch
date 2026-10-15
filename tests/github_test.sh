#!/usr/bin/env bash
# lib/github.sh のユニットテスト。API/DL を seam で差し替え、JSON 解析と URL 組み立てを
# network 無しで検証する（jq の解析は実物を使う＝CI/ローカルとも jq 前提）。

# スタブ（seam）は被テスト関数の中から間接的に呼ばれるため、静的には SC2317 / SC2329 に見える。
# shellcheck disable=SC2317,SC2329

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

# --- asset digest（Releases API）による照合（#20） ---
_digest_json() { # name hex
  printf '{"assets":[{"name":"other.deb","digest":"sha256:%064d"},{"name":"%s","digest":"sha256:%s"}]}' 0 "$1" "$2"
}
_EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

test_github_asset_digest_picks_named_asset() {
  # $() の中で呼ばれるので、API に渡されたパスはファイルで受ける。
  local capf; capf=$(mktemp)
  booch_github_api() { echo "$1" > "$capf"; _digest_json a.deb "$_EMPTY_SHA"; }
  assert_eq "$_EMPTY_SHA" "$(booch_github_asset_digest o/r v1.0.0 a.deb)"
  assert_eq "repos/o/r/releases/tags/v1.0.0" "$(cat "$capf")"
  rm -f "$capf"
}
# digest が無い / sha256 以外の形式なら空で 0（照合を飛ばす判断は呼び出し側）。
test_github_asset_digest_empty_when_absent() {
  booch_github_api() { printf '{"assets":[{"name":"a.deb","digest":null}]}'; }
  assert_eq "" "$(booch_github_asset_digest o/r v1 a.deb)"
  booch_github_api() { printf '{"assets":[{"name":"a.deb","digest":"sha512:abcd"}]}'; }
  assert_eq "" "$(booch_github_asset_digest o/r v1 a.deb)"
}
test_github_asset_digest_fails_when_api_fails() {
  booch_github_api() { return 22; }
  local rc; if booch_github_asset_digest o/r v1 a.deb >/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
# 非 JSON（プロキシの HTML 等）と空の応答は「digest が無い」ではなく取得の失敗。pipefail の
# 有無で判定が変わらないことも見る。
test_github_asset_digest_fails_on_non_json_regardless_of_pipefail() {
  local rc
  booch_github_api() { printf '<html>rate limited</html>'; }
  if (set +o pipefail; booch_github_asset_digest o/r v1 a.deb >/dev/null); then rc=0; else rc=$?; fi
  assert_status 1 "$rc" "pipefail なし"
  if (set -o pipefail; booch_github_asset_digest o/r v1 a.deb >/dev/null); then rc=0; else rc=$?; fi
  assert_status 1 "$rc" "pipefail あり"
  booch_github_api() { :; }
  if booch_github_asset_digest o/r v1 a.deb >/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc" "空の応答"
}

test_github_verify_asset_accepts_matching_digest() {
  local f; f=$(mktemp)
  booch_github_api() { _digest_json a.deb "$_EMPTY_SHA"; }
  local rc; if booch_github_verify_asset o/r v1 a.deb "$f" 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  rm -f "$f"
}
test_github_verify_asset_rejects_mismatch() {
  local f; f=$(mktemp); echo tampered > "$f"
  booch_github_api() { _digest_json a.deb "$_EMPTY_SHA"; }
  local rc; if booch_github_verify_asset o/r v1 a.deb "$f" 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  rm -f "$f"
}
# digest が付いていない（古いリリース）ときは警告して照合を飛ばす（導入は止めない）。
test_github_verify_asset_warns_and_skips_without_digest() {
  local f err; f=$(mktemp); echo anything > "$f"
  booch_github_api() { printf '{"assets":[]}'; }
  local rc; if err=$(booch_github_verify_asset o/r v1 a.deb "$f" 2>&1); then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_contains "$err" "digest が無い"
  rm -f "$f"
}
# API の失敗（レート制限など）では照合を飛ばさず中断する（未検証の資産を導入へ進めない）。
test_github_verify_asset_fails_when_api_fails() {
  local f err; f=$(mktemp); echo anything > "$f"
  booch_github_api() { return 22; }
  local rc; if err=$(booch_github_verify_asset o/r v1 a.deb "$f" 2>&1); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$err" "中断します"
  rm -f "$f"
}
# github.sh だけを読む利用側（CI の shellcheck 導入など）でも照合関数が使える。
test_github_sources_verify_when_missing() {
  local out
  out=$(bash -c 'unset BOOCH_ROOT; source "$1/lib/github.sh"; declare -F booch_verify_sha256' _ "$BOOCH_ROOT")
  assert_eq "booch_verify_sha256" "$out"
}
# ファイルとして置かれていない読み込み方（source <(...)）では BASH_SOURCE から辿れないが、
# BOOCH_ROOT があればそこから読む。どちらも無くても source 自体は失敗しない。
test_github_sources_verify_from_booch_root_or_tolerates_absence() {
  local out
  out=$(bash -c 'source <(cat "$BOOCH_ROOT/lib/github.sh"); declare -F booch_verify_sha256')
  assert_eq "booch_verify_sha256" "$out"
  out=$(bash -c 'set -e; src=$(cat "$1/lib/github.sh"); unset BOOCH_ROOT; source <(printf "%s\n" "$src"); echo ok' _ "$BOOCH_ROOT")
  assert_eq "ok" "$out"
}

run_tests
