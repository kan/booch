#!/usr/bin/env bash
# lib/apt.sh のユニットテスト。副作用シーム（dist_exists / install_key / write_list）を
# スタブで差し替え、フォールバック解決と冪等スキップの純粋ロジックを検証する。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/apt.sh
source "$BOOCH_ROOT/lib/apt.sh"

# --- コードネーム解決 ---
test_apt_resolve_uses_wanted_when_dist_exists() {
  booch_apt_dist_exists() { return 0; }
  assert_eq "resolute" "$(booch_apt_resolve_codename https://example resolute noble)"
}

test_apt_resolve_falls_back_when_dist_missing() {
  booch_apt_dist_exists() { return 1; }
  assert_eq "noble" "$(booch_apt_resolve_codename https://example resolute noble 2>/dev/null)"
}

# stdout はコードネームのみ（末尾改行で汚さない）。$() は末尾改行を落とすので
# 番兵を連結して検出する。
test_apt_resolve_stdout_has_no_trailing_newline() {
  booch_apt_dist_exists() { return 0; }
  local out
  out=$(booch_apt_resolve_codename https://example resolute noble; printf END)
  assert_eq "resoluteEND" "$out"
}

# フォールバック時は理由を stderr に出す（stdout はコードネームのみで汚さない）。
test_apt_resolve_fallback_warns_on_stderr() {
  booch_apt_dist_exists() { return 1; }
  local err
  err=$(booch_apt_resolve_codename https://example resolute noble 2>&1 >/dev/null)
  assert_contains "$err" "フォールバック"
}

# --- add_repo の冪等・実行 ---
test_apt_add_repo_skips_when_list_exists() {
  local d; d=$(mktemp -d)
  export BOOCH_APT_SOURCES_DIR="$d"
  : > "$d/foo.list"
  local called=0
  booch_apt_install_key() { called=1; }
  booch_apt_write_list()  { called=1; }
  booch_apt_add_repo foo https://k /tmp/kr raw "deb x"
  rm -rf "$d"
  assert_eq "0" "$called"
}

test_apt_add_repo_installs_when_absent() {
  local d; d=$(mktemp -d)
  export BOOCH_APT_SOURCES_DIR="$d"
  local key_called=0 list_called=0 wrote_line="" wrote_mode=""
  booch_apt_install_key() { key_called=1; wrote_mode=$3; }
  booch_apt_write_list()  { list_called=1; wrote_line=$2; }
  booch_apt_add_repo foo https://k /etc/apt/keyrings/foo.gpg dearmor "deb the-line"
  rm -rf "$d"
  assert_eq "1" "$key_called"  "install_key 呼ばれる"
  assert_eq "1" "$list_called" "write_list 呼ばれる"
  assert_eq "deb the-line" "$wrote_line"
  assert_eq "dearmor" "$wrote_mode"
}

test_apt_add_repo_returns_ok_on_install() {
  local d; d=$(mktemp -d)
  export BOOCH_APT_SOURCES_DIR="$d"
  booch_apt_install_key() { :; }
  booch_apt_write_list()  { :; }
  local rc
  if booch_apt_add_repo foo https://k /tmp/kr raw "deb x"; then rc=0; else rc=$?; fi
  rm -rf "$d"
  assert_status 0 "$rc"
}

test_apt_add_repo_rejects_bad_name() {
  local d; d=$(mktemp -d)
  export BOOCH_APT_SOURCES_DIR="$d"
  local rc
  if booch_apt_add_repo "../evil" https://k /tmp/kr raw "deb x" 2>/dev/null; then rc=0; else rc=$?; fi
  rm -rf "$d"
  assert_status 2 "$rc"
}

test_apt_install_key_rejects_unknown_mode() {
  local rc
  if booch_apt_install_key https://k /tmp/kr bogus 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 2 "$rc"
}

# --- 実 install_key 本体を PATH シム（curl/sudo/gpg）で駆動する（sudo/network 不要） ---
# $1=作業 bin の置き先, $2=gpg の終了コード。curl は -o 先へダミーを書き、sudo は
# 特権を外して exec、gpg は指定コードで終了する（成功時のみ keyring を書く）。
_apt_make_shims() {
  local bin="$1/bin" gpg_rc="$2"
  mkdir -p "$bin"
  cat > "$bin/curl" <<'SH'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) shift ;; esac
done
[ -n "$out" ] && printf 'DUMMYKEY\n' > "$out"
SH
  cat > "$bin/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
  cat > "$bin/gpg" <<SH
#!/usr/bin/env bash
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift 2 ;; *) shift ;; esac
done
if [ "$gpg_rc" = 0 ] && [ -n "\$out" ]; then printf 'BINKEY\n' > "\$out"; fi
exit $gpg_rc
SH
  chmod +x "$bin"/curl "$bin"/sudo "$bin"/gpg
}

# raw モードは gpg を使わず temp をそのまま配置する → 成功し keyring ができる。
test_apt_install_key_raw_success() {
  local d; d=$(mktemp -d)
  _apt_make_shims "$d" 0
  local keyring="$d/keys/foo.gpg" rc
  if PATH="$d/bin:$PATH" booch_apt_install_key https://x "$keyring" raw; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_eq "DUMMYKEY" "$(cat "$keyring" 2>/dev/null)"
  rm -rf "$d"
}

# dearmor で gpg が失敗したら install_key は非 0 を返し、keyring を残さない（バグ回帰）。
test_apt_install_key_dearmor_failure_returns_error() {
  local d; d=$(mktemp -d)
  _apt_make_shims "$d" 1
  local keyring="$d/keys/foo.gpg" rc
  if PATH="$d/bin:$PATH" booch_apt_install_key https://x "$keyring" dearmor 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$keyring"
  rm -rf "$d"
}

# 上記が add_repo まで波及すること: gpg 失敗なら .list を書かず非 0（壊れた repo を残さない）。
test_apt_add_repo_no_list_when_key_install_fails_for_real() {
  local d; d=$(mktemp -d)
  _apt_make_shims "$d" 1
  export BOOCH_APT_SOURCES_DIR="$d/sources"
  mkdir -p "$BOOCH_APT_SOURCES_DIR"
  local rc
  if PATH="$d/bin:$PATH" booch_apt_add_repo foo https://x "$d/keys/foo.gpg" dearmor "deb x" 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$BOOCH_APT_SOURCES_DIR/foo.list"
  rm -rf "$d"
}

# 鍵取得に失敗したら deb 行を書かない（壊れた repo を残さない）。
test_apt_add_repo_aborts_when_key_fails() {
  local d; d=$(mktemp -d)
  export BOOCH_APT_SOURCES_DIR="$d"
  local list_called=0
  booch_apt_install_key() { return 1; }
  booch_apt_write_list()  { list_called=1; }
  local rc
  if booch_apt_add_repo foo https://k /tmp/kr raw "deb x"; then rc=0; else rc=$?; fi
  rm -rf "$d"
  assert_status 1 "$rc"
  assert_eq "0" "$list_called" "鍵失敗時は write_list を呼ばない"
}

run_tests
