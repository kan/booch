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
  : > "$d/foo.list"; : > "$d/kr"   # list と keyring 両方そろっている
  local called=0
  booch_apt_install_key() { called=1; }
  booch_apt_write_list()  { called=1; }
  booch_apt_add_repo foo https://k "$d/kr" raw "deb x"
  rm -rf "$d"
  assert_eq "0" "$called"
}

# list はあるが keyring が欠けていれば、鍵を入れ直して自己修復する。
test_apt_add_repo_reinstalls_when_keyring_missing() {
  local d; d=$(mktemp -d)
  export BOOCH_APT_SOURCES_DIR="$d"
  : > "$d/foo.list"   # list はあるが keyring（$d/kr）は無い
  local key_called=0
  booch_apt_install_key() { key_called=1; }
  booch_apt_write_list()  { :; }
  booch_apt_add_repo foo https://k "$d/kr" raw "deb x"
  rm -rf "$d"
  assert_eq "1" "$key_called" "keyring 欠損なら鍵を入れ直す"
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

# --- booch_apt_ensure（不足分のみ導入） ---
test_apt_ensure_skips_when_all_installed() {
  booch_apt_pkg_installed() { return 0; }
  local called=0
  booch_apt_install() { called=1; }
  local rc
  if booch_apt_ensure curl gnupg; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_eq "0" "$called" "全導入済みなら install を呼ばない"
}

test_apt_ensure_installs_only_missing() {
  # gnupg だけ未導入、他は導入済み。
  booch_apt_pkg_installed() { [ "$1" = gnupg ] && return 1; return 0; }
  local args="__unset__"
  booch_apt_install() { args="$*"; }
  booch_apt_ensure curl gnupg ca-certificates
  assert_eq "gnupg" "$args"
}

# 複数未導入のとき、未導入のものだけを元の順序で渡す（並べ替え・取りこぼし・
# 重複が無いことまで見る）。
test_apt_ensure_passes_all_missing_in_order() {
  booch_apt_pkg_installed() { [ "$1" = gnupg ] && return 0; return 1; }
  local args="__unset__"
  booch_apt_install() { args="$*"; }
  booch_apt_ensure curl gnupg ca-certificates
  assert_eq "curl ca-certificates" "$args"
}

test_apt_ensure_zero_args_is_noop() {
  booch_apt_pkg_installed() { return 1; }
  local called=0
  booch_apt_install() { called=1; }
  local rc
  if booch_apt_ensure; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_eq "0" "$called" "引数なしなら install を呼ばない"
}

test_apt_ensure_propagates_install_failure() {
  booch_apt_pkg_installed() { return 1; }   # 全て未導入
  booch_apt_install() { return 1; }
  local rc
  if booch_apt_ensure curl; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- booch_apt_warn_autoremove ---
test_apt_warn_autoremove_silent_when_zero() {
  booch_apt_autoremove_count() { echo 0; }
  local rc
  if booch_apt_warn_autoremove 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

test_apt_warn_autoremove_warns_when_present() {
  booch_apt_autoremove_count() { echo 3; }
  local tmpout tmperr rc
  tmpout=$(mktemp); tmperr=$(mktemp)
  if booch_apt_warn_autoremove >"$tmpout" 2>"$tmperr"; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$(cat "$tmperr")" "3"
  assert_eq "" "$(cat "$tmpout")" "通知は stdout を汚さない"
  rm -f "$tmpout" "$tmperr"
}

# 退化ケース（awk 不在等で count が空/非数値）でも構文エラーにならず 0 扱い。
test_apt_warn_autoremove_treats_nonnumeric_as_zero() {
  booch_apt_autoremove_count() { echo ""; }
  local rc
  if booch_apt_warn_autoremove 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

# --- booch_apt_sync（sudo/upgrade/warn を seam で制御） ---
# stub は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317
test_apt_sync_returns_1_when_update_fails() {
  sudo() { case "$2" in update) return 1 ;; *) return 0 ;; esac; }
  booch_apt_upgrade() { return 0; }
  booch_apt_warn_autoremove() { return 0; }
  local rc; if booch_apt_sync git >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

test_apt_sync_returns_1_when_install_fails() {
  sudo() { case "$2" in install) return 1 ;; *) return 0 ;; esac; }
  booch_apt_upgrade() { return 0; }
  booch_apt_warn_autoremove() { return 0; }
  local rc; if booch_apt_sync git >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# upgrade 失敗は best-effort（全体は成功）。
test_apt_sync_tolerates_upgrade_failure() {
  sudo() { return 0; }
  booch_apt_upgrade() { return 1; }
  booch_apt_warn_autoremove() { return 0; }
  local rc; if booch_apt_sync git >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

# --- booch_apt_add_ppa（temp の sources.d / add-apt-repository を seam） ---
test_apt_add_ppa_skips_when_present() {
  BOOCH_APT_SOURCES_DIR=$(mktemp -d)
  echo "deb http://ppa.example/git-core/ppa ..." > "$BOOCH_APT_SOURCES_DIR/git.list"
  local added=0
  sudo() { added=1; }
  booch_apt_add_ppa ppa:git-core/ppa >/dev/null 2>&1
  assert_eq "0" "$added" "既存なら add-apt-repository を呼ばない"
  rm -rf "$BOOCH_APT_SOURCES_DIR"
}

test_apt_add_ppa_adds_when_absent() {
  BOOCH_APT_SOURCES_DIR=$(mktemp -d)
  local got=""
  sudo() { shift; got="$*"; }   # "add-apt-repository -y ppa:..." の add-apt-repository 以降
  booch_apt_add_ppa ppa:git-core/ppa >/dev/null 2>&1
  assert_contains "$got" "ppa:git-core/ppa"
  rm -rf "$BOOCH_APT_SOURCES_DIR"
}

# 追加失敗 + allow_fail なら 0、無しなら 1。
test_apt_add_ppa_fail_open_with_allow_fail() {
  BOOCH_APT_SOURCES_DIR=$(mktemp -d)
  sudo() { return 1; }
  local rc; if booch_apt_add_ppa ppa:x/y "x/y" true >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  rm -rf "$BOOCH_APT_SOURCES_DIR"
}

test_apt_add_ppa_fail_closed_by_default() {
  BOOCH_APT_SOURCES_DIR=$(mktemp -d)
  sudo() { return 1; }
  local rc; if booch_apt_add_ppa ppa:x/y >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  rm -rf "$BOOCH_APT_SOURCES_DIR"
}

# --- booch_apt_pin_origin（temp の preferences.d） ---
test_apt_pin_origin_writes_file() {
  BOOCH_APT_PREFERENCES_DIR=$(mktemp -d)
  sudo() { "$@"; }   # tee を sudo 無しで実行
  booch_apt_pin_origin nodesource nodejs deb.nodesource.com 600
  local f="$BOOCH_APT_PREFERENCES_DIR/nodesource"
  assert_contains "$(cat "$f")" "Package: nodejs"
  assert_contains "$(cat "$f")" "Pin: origin deb.nodesource.com"
  assert_contains "$(cat "$f")" "Pin-Priority: 600"
  rm -rf "$BOOCH_APT_PREFERENCES_DIR"
}

test_apt_pin_origin_skips_when_present() {
  BOOCH_APT_PREFERENCES_DIR=$(mktemp -d)
  echo "existing" > "$BOOCH_APT_PREFERENCES_DIR/nodesource"
  sudo() { "$@"; }
  booch_apt_pin_origin nodesource nodejs deb.nodesource.com 600
  assert_eq "existing" "$(cat "$BOOCH_APT_PREFERENCES_DIR/nodesource")"
  rm -rf "$BOOCH_APT_PREFERENCES_DIR"
}

run_tests
