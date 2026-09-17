#!/usr/bin/env bash
# jobs/codex.sh のユニットテスト。seam をスタブで差し替え、分岐・インストーラの呼び方・
# 旧版の掃除・旧単体バイナリの削除・arch を検証する。

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
# shellcheck source=lib/github.sh
source "$BOOCH_ROOT/lib/github.sh"
# shellcheck source=jobs/codex.sh
source "$BOOCH_ROOT/jobs/codex.sh"

# 実環境の ~/.codex と /usr/local/bin/codex に触れないよう、既定では存在しないパスへ向ける
# （job_codex は旧単体バイナリの削除を sudo で試みる）。個々のテストが必要に応じて上書きする。
booch_codex_standalone_dir() { printf '/nonexistent/booch-test/standalone'; }
booch_codex_legacy_path() { printf '/nonexistent/booch-test/codex'; }
export CODEX_INSTALL_DIR=/nonexistent/booch-test/bin
sudo() { echo "テストから sudo が呼ばれた: $*" >&2; return 1; }

# 導入先に、--version で指定の文字列を返す偽の codex を置く。
_fake_codex_bin() { # dir version_output
  mkdir -p "$1"
  printf '#!/bin/sh\necho "%s"\n' "$2" > "$1/codex"
  chmod +x "$1/codex"
}

# --- バージョン解析（導入先の codex を実行して解析する） ---
test_codex_installed_version_parses_version() {
  local d; d=$(mktemp -d)
  _fake_codex_bin "$d" "codex-cli 0.142.3"
  assert_eq "0.142.3" "$(CODEX_INSTALL_DIR=$d booch_codex_installed_version)"
  rm -rf "$d"
}
# 末尾にハッシュ等が付いても X.Y.Z を拾う（$NF 方式の脆さに対する回帰ガード）。
test_codex_installed_version_robust_to_trailing_token() {
  local d; d=$(mktemp -d)
  _fake_codex_bin "$d" "codex-cli 0.142.3 (abcdef)"
  assert_eq "0.142.3" "$(CODEX_INSTALL_DIR=$d booch_codex_installed_version)"
  rm -rf "$d"
}
# PATH 上に codex があっても、導入先に無ければ未導入（旧単体バイナリからの移行で導入を走らせる）。
test_codex_installed_version_ignores_codex_on_path() {
  local d; d=$(mktemp -d)
  codex() { echo "codex-cli 0.100.0"; }
  assert_eq "" "$(CODEX_INSTALL_DIR=$d booch_codex_installed_version)"
  rm -rf "$d"
}
test_codex_bin_dir_defaults_to_local_bin() {
  assert_eq "/h/.local/bin" "$(HOME=/h CODEX_INSTALL_DIR='' booch_codex_bin_dir)"
}

# --- 純粋関数 / arch ---
test_codex_arch_x86_64() {
  uname() { echo x86_64; }
  assert_eq "x86_64" "$(booch_codex_arch)"
}
test_codex_arch_aarch64() {
  uname() { echo aarch64; }
  assert_eq "aarch64" "$(booch_codex_arch)"
}
test_codex_arch_unsupported_fails() {
  uname() { echo riscv64; }
  local rc; if booch_codex_arch >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- job_codex 分岐（実処理はスタブ。latest は rust-v 付きを返す） ---
_run_job_codex() { # installed latest_tag
  booch_runner_init
  local _inst=$1 _lat=$2
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf '%s' "$_inst"; }
  booch_codex_latest() { printf '%s' "$_lat"; }
  booch_codex_install() { :; }
  export BOOCH_JOB=codex
  job_codex
}

test_codex_installs_when_missing() {
  _run_job_codex "" "rust-v0.20.0"
  assert_eq "Codex CLI|installed||0.20.0" "$(cat "$BOOCH_RESULT_DIR/codex.result")"
}
test_codex_updates_when_differ() {
  _run_job_codex "0.19.0" "rust-v0.20.0"
  assert_eq "Codex CLI|updated|0.19.0|0.20.0" "$(cat "$BOOCH_RESULT_DIR/codex.result")"
}
# rust-v 正規化により、素のバージョンとタグが同一なら current（永久更新にならない）。
test_codex_current_when_equal_after_normalize() {
  _run_job_codex "0.20.0" "rust-v0.20.0"
  assert_eq "Codex CLI|current|0.20.0|" "$(cat "$BOOCH_RESULT_DIR/codex.result")"
}
# v 単独タグでも 2 段目の strip で正規化され current（${norm#v} の回帰ガード）。
test_codex_current_when_tag_has_v_prefix() {
  _run_job_codex "0.20.0" "v0.20.0"
  assert_eq "Codex CLI|current|0.20.0|" "$(cat "$BOOCH_RESULT_DIR/codex.result")"
}

test_codex_fails_when_latest_unavailable() {
  booch_runner_init
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf '0.19.0'; }
  booch_codex_latest() { return 1; }
  booch_codex_install() { :; }
  export BOOCH_JOB=codex
  local rc; if job_codex >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$BOOCH_RESULT_DIR/codex.result"
}

test_codex_fails_when_arch_unsupported() {
  booch_runner_init
  booch_codex_arch() { return 1; }
  export BOOCH_JOB=codex
  local rc; if job_codex >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# job_codex が rust-v を外した版を install へ渡す（導入と比較で同じ版を使う）。
test_codex_job_passes_normalized_version_to_install() {
  booch_runner_init
  local cap_ver=""
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf '0.19.0'; }
  booch_codex_latest() { printf 'rust-v0.20.0'; }
  booch_codex_install() { cap_ver=$1; }
  export BOOCH_JOB=codex
  job_codex
  assert_eq "0.20.0" "$cap_ver"
}

# --- booch_codex_install（取得 / 実行 / 掃除の seam をスタブ） ---
# install は受け取った版をインストーラへ渡し、成功後に直前の版を残して旧版を掃除する。
# 捕捉変数は install のローカルと衝突しない名前。
test_codex_install_passes_version_to_installer() {
  local cap_ver="" cap_keep=""
  booch_codex_current_release() { printf '0.19.0-t'; }
  booch_codex_fetch_installer() { : > "$1"; }
  booch_codex_run_installer() { cap_ver=$2; }
  booch_codex_prune_releases() { cap_keep=$1; }
  booch_codex_install 0.20.0
  assert_eq "0.20.0" "$cap_ver"
  assert_eq "0.19.0-t" "$cap_keep"
}
test_codex_install_fails_when_fetch_fails() {
  local cap_run=""
  booch_codex_fetch_installer() { return 1; }
  booch_codex_run_installer() { cap_run=yes; }
  local rc; if booch_codex_install 0.20.0 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "" "$cap_run"
}
# インストーラが失敗したら、旧版の掃除に進まない。
test_codex_install_fails_when_installer_fails() {
  local cap_pruned=""
  booch_codex_fetch_installer() { : > "$1"; }
  booch_codex_run_installer() { return 1; }
  booch_codex_prune_releases() { cap_pruned=yes; }
  local rc; if booch_codex_install 0.20.0 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "" "$cap_pruned"
}

# --- job_codex からの旧単体バイナリの削除 ---
# 導入済み（installed が空でない）なら導入先に偽の codex を置き、版は最新と一致させて
# 導入を呼ばない状態で job_codex を走らせる。旧単体バイナリの削除は cap_legacy に記録する。
_job_codex_legacy() { # installed remove_rc
  booch_runner_init
  local bin; bin=$(mktemp -d)
  [ -n "$1" ] && _fake_codex_bin "$bin" "codex-cli $1"
  export CODEX_INSTALL_DIR=$bin
  local _inst=$1 _rc=$2
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf '%s' "$_inst"; }
  booch_codex_latest() { printf 'rust-v0.20.0'; }
  booch_codex_install() { :; }
  booch_codex_remove_legacy() { cap_legacy=yes; return "$_rc"; }
  export BOOCH_JOB=codex
  job_codex
}
# 版が最新と一致して導入が呼ばれない回でも削除を試みる（前回の削除失敗を再試行する）。
test_codex_job_removes_legacy_even_when_current() {
  local cap_legacy=""
  _job_codex_legacy 0.20.0 0
  assert_eq "yes" "$cap_legacy"
}
# インストーラでの導入が済んでいない（導入に失敗した等）ときは消さない。
test_codex_job_keeps_legacy_when_not_installed() {
  local cap_legacy=""
  _job_codex_legacy "" 0
  assert_eq "" "$cap_legacy"
}
test_codex_job_fails_when_legacy_removal_fails() {
  local cap_legacy="" rc
  if _job_codex_legacy 0.20.0 1 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# インストーラには版と非対話の指定を渡し、HOME は一時ディレクトリに差し替える（シェルの
# 設定ファイルへの PATH 追記を捨てる）。CODEX_HOME と導入先は元の HOME を基準にする。
test_codex_run_installer_passes_env_and_release() {
  local d; d=$(mktemp -d)
  cat > "$d/install.sh" <<'EOF'
printf '%s\n' "$HOME" "$CODEX_HOME" "$CODEX_INSTALL_DIR" "$CODEX_NON_INTERACTIVE" "$*"
EOF
  local out
  out=$(HOME=/realhome CODEX_HOME='' CODEX_INSTALL_DIR='' booch_codex_run_installer "$d/install.sh" 0.20.0)
  local lines; mapfile -t lines <<< "$out"
  assert_not_contains "${lines[0]}" "/realhome"
  assert_eq "/realhome/.codex" "${lines[1]}"
  assert_eq "/realhome/.local/bin" "${lines[2]}"
  assert_eq "true" "${lines[3]}"
  assert_eq "--release 0.20.0" "${lines[4]}"
  rm -rf "$d"
}

# --- 旧版の掃除 ---
_standalone_fixture() { # root versions...
  local root=$1; shift
  mkdir -p "$root/releases/.staging.x"
  local v; for v in "$@"; do mkdir -p "$root/releases/$v"; done
}
test_codex_prune_keeps_current_and_previous() {
  local d; d=$(mktemp -d)
  _standalone_fixture "$d" 0.1.0-t 0.2.0-t 0.3.0-t
  ln -s "$d/releases/0.3.0-t" "$d/current"
  booch_codex_standalone_dir() { printf '%s' "$d"; }
  booch_codex_prune_releases 0.2.0-t
  assert_eq "0.2.0-t 0.3.0-t" "$(cd "$d/releases" && echo *)"
  [ -d "$d/releases/.staging.x" ] || { echo "staging を消した"; return 1; }
  rm -rf "$d"
}
# 基準のディレクトリが symlink 経由でも、current を消さない（パスでの比較に対する回帰ガード）。
test_codex_prune_keeps_current_via_symlinked_root() {
  local d; d=$(mktemp -d)
  _standalone_fixture "$d/real" 0.1.0-t 0.3.0-t
  ln -s "$d/real" "$d/link"
  ln -s "$d/real/releases/0.3.0-t" "$d/real/current"
  booch_codex_standalone_dir() { printf '%s' "$d/link/"; }
  booch_codex_prune_releases ""
  assert_eq "0.3.0-t" "$(cd "$d/real/releases" && echo *)"
  rm -rf "$d"
}
test_codex_prune_without_previous_keeps_only_current() {
  local d; d=$(mktemp -d)
  _standalone_fixture "$d" 0.1.0-t 0.3.0-t
  ln -s "$d/releases/0.3.0-t" "$d/current"
  booch_codex_standalone_dir() { printf '%s' "$d"; }
  booch_codex_prune_releases ""
  assert_eq "0.3.0-t" "$(cd "$d/releases" && echo *)"
  rm -rf "$d"
}
# current が無い（インストーラの配置が想定と違う）ときは何も消さない。
test_codex_prune_noop_without_current() {
  local d; d=$(mktemp -d)
  _standalone_fixture "$d" 0.1.0-t 0.3.0-t
  booch_codex_standalone_dir() { printf '%s' "$d"; }
  booch_codex_prune_releases ""
  assert_eq "0.1.0-t 0.3.0-t" "$(cd "$d/releases" && echo *)"
  rm -rf "$d"
}

# --- 旧単体バイナリの削除 ---
_legacy_removal() { # setup_fn → "absent" / "present"
  local d; d=$(mktemp -d)
  "$1" "$d"
  booch_codex_legacy_path() { printf '%s' "$d/codex"; }
  sudo() { "$@"; }
  booch_codex_remove_legacy
  if [ -e "$d/codex" ] || [ -L "$d/codex" ]; then echo present; else echo absent; fi
  rm -rf "$d"
}
_legacy_codex_file() { _fake_codex_bin "$1" "codex-cli 0.100.0"; }
_legacy_other_file() { _fake_codex_bin "$1" "something else 1.0.0"; }
_legacy_symlink() { _fake_codex_bin "$1/real" "codex-cli 0.100.0"; ln -s "$1/real/codex" "$1/codex"; }
test_codex_remove_legacy_removes_codex_binary() {
  assert_eq "absent" "$(_legacy_removal _legacy_codex_file)"
}
test_codex_remove_legacy_keeps_other_binary() {
  assert_eq "present" "$(_legacy_removal _legacy_other_file)"
}
test_codex_remove_legacy_keeps_symlink() {
  assert_eq "present" "$(_legacy_removal _legacy_symlink)"
}
test_codex_remove_legacy_noop_when_absent() {
  booch_codex_remove_legacy
}

# --- runner 経由（declare -f 伝播＋失敗時の自動 failed 記録） ---
# shellcheck disable=SC2317,SC2329  # スタブは runner の bash -c 子経由でのみ呼ばれる
test_codex_via_runner_reports_installed() {
  booch_runner_init
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf ''; }
  booch_codex_latest() { printf 'rust-v0.20.0'; }
  booch_codex_install() { :; }
  booch_job codex "Codex CLI" job_codex 60
  local out; out=$(booch_run)
  assert_contains "$out" "Codex CLI"
  assert_contains "$out" "installed"
  assert_contains "$out" "0.20.0"
}

# shellcheck disable=SC2317,SC2329
test_codex_via_runner_install_failure_is_failed() {
  booch_runner_init
  booch_codex_arch() { echo x86_64; }
  booch_codex_installed_version() { printf ''; }
  booch_codex_latest() { printf 'rust-v0.20.0'; }
  booch_codex_install() { return 1; }
  booch_job codex "Codex CLI" job_codex 60
  local out rc; if out=$(booch_run); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "failed"
}

run_tests
