#!/usr/bin/env bash
# install.sh のユニットテスト。BOOCH_INSTALL_NO_RUN=1 で関数定義だけ読み込み、副作用の
# 継ぎ目（apt / gh / git / exec）をスタブして network / sudo / 実行なしで分岐を検証する。
# 実地スモーク（clean 環境での curl|bash）は別途。

# スタブ（seam）は間接呼び出しで SC2317 に見えるため抑制する。
# shellcheck disable=SC2317,SC2329

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# main を実行させず関数定義だけ読み込む（source は同一シェルなので通常代入で十分）。
BOOCH_INSTALL_NO_RUN=1
# shellcheck source=install.sh
source "$BOOCH_ROOT/install.sh"

# --- clone（既存=pull / 無し=gh clone） ---
test_install_clone_uses_gh_when_absent() {
  local d; d=$(mktemp -d)   # .git 無し
  local cap=""
  booch_install_gh() { cap="$*"; }
  booch_install_clone youraccount/dotfiles "$d/df" >/dev/null
  assert_eq "repo clone youraccount/dotfiles $d/df" "$cap"
  rm -rf "$d"
}
test_install_clone_pulls_when_present() {
  local d; d=$(mktemp -d); mkdir -p "$d/df/.git"
  local cap=""
  booch_install_git() { cap="$*"; }
  booch_install_clone youraccount/dotfiles "$d/df" >/dev/null
  assert_eq "-C $d/df pull --ff-only" "$cap"
  rm -rf "$d"
}

# --- apt update（取得失敗を非 0 にして止める） ---
test_install_apt_update_requests_error_mode_any() {
  local cap=""
  booch_install_apt() { cap="$*"; }
  booch_install_apt_update
  assert_eq "update -qq -o APT::Update::Error-Mode=any" "$cap"
}
test_install_prereqs_stops_before_install_when_update_fails() {
  local installed=0 rc
  _bi_have() { [ "$1" = gh ]; }   # git / curl が無い
  booch_install_apt() { case "$1" in update) return 100 ;; install) installed=1 ;; esac; }
  if booch_install_prereqs >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "0" "$installed" "update 失敗で install へ進まない"
}

# --- ensure_booch（submodule あり / sibling あり / どちらも無し→clone） ---
test_install_ensure_booch_ok_when_submodule_present() {
  local d; d=$(mktemp -d); mkdir -p "$d/df/vendor/booch/lib"; : > "$d/df/vendor/booch/lib/runner.sh"
  local cloned=0
  booch_install_git() { case "$*" in *clone*) cloned=1 ;; esac; return 0; }
  booch_install_ensure_booch "$d/df" v1.0.0 >/dev/null
  assert_eq "0" "$cloned" "submodule にあれば clone しない"
  rm -rf "$d"
}
test_install_ensure_booch_ok_when_sibling_present() {
  local d; d=$(mktemp -d); mkdir -p "$d/booch/lib" "$d/df"; : > "$d/booch/lib/runner.sh"
  local cloned=0
  booch_install_git() { case "$*" in *clone*) cloned=1 ;; esac; return 0; }
  booch_install_ensure_booch "$d/df" v1.0.0 >/dev/null
  assert_eq "0" "$cloned" "sibling にあれば clone しない"
  rm -rf "$d"
}
test_install_ensure_booch_clones_sibling_when_absent() {
  local d; d=$(mktemp -d); mkdir -p "$d/df"
  local cap_clone="" cap_checkout=""
  booch_install_git() {
    case "$*" in
      clone\ *) cap_clone="$*" ;;
      *checkout*) cap_checkout="$*" ;;
    esac
    return 0
  }
  booch_install_ensure_booch "$d/df" v1.2.3 >/dev/null
  assert_contains "$cap_clone" "clone https://github.com/kan/booch $d/booch"
  assert_contains "$cap_checkout" "checkout v1.2.3"
  rm -rf "$d"
}

# --- run（エントリ自動検出 / override / 無し） ---
test_install_run_detects_bootstrap() {
  local d; d=$(mktemp -d); : > "$d/bootstrap.sh"
  local cap=""
  booch_install_exec() { cap="$1|$2"; }
  booch_install_run "$d" >/dev/null
  assert_eq "$d|bootstrap.sh" "$cap"
  rm -rf "$d"
}
test_install_run_detects_setup_dotfiles() {
  local d; d=$(mktemp -d); mkdir -p "$d/setup"; : > "$d/setup/dotfiles"
  local cap=""
  booch_install_exec() { cap="$1|$2"; }
  booch_install_run "$d" >/dev/null
  assert_eq "$d|setup/dotfiles" "$cap"
  rm -rf "$d"
}
test_install_run_uses_override() {
  local d; d=$(mktemp -d); : > "$d/bootstrap.sh"
  local cap=""
  booch_install_exec() { cap="$1|$2"; }
  booch_install_run "$d" custom/run.sh >/dev/null
  assert_eq "$d|custom/run.sh" "$cap"
  rm -rf "$d"
}
test_install_run_warns_when_no_entry() {
  local d; d=$(mktemp -d)
  local exec_called=0
  booch_install_exec() { exec_called=1; }
  booch_install_run "$d" >/dev/null 2>&1
  assert_eq "0" "$exec_called" "エントリが無ければ実行しない"
  rm -rf "$d"
}

# --- main（引数解析 + ステップ順 / 不明引数 / --help） ---
test_install_main_runs_steps_in_order() {
  local log=""
  booch_install_prereqs()      { log="$log prereqs"; }
  booch_install_auth()         { log="$log auth"; }
  booch_install_clone()        { log="$log clone:$1:$2"; }
  booch_install_ensure_booch() { log="$log booch:$1:$2"; }
  booch_install_run()          { log="$log run:$1:$2"; }
  booch_install_main --dir /tmp/df --repo me/dots --booch-ref v9 --run go.sh >/dev/null
  assert_eq " prereqs auth clone:me/dots:/tmp/df booch:/tmp/df:v9 run:/tmp/df:go.sh" "$log"
}
test_install_main_requires_repo() {
  # --repo も BOOCH_INSTALL_REPO も無ければ、副作用の前に非 0 で中断する。
  # test_* はサブシェル隔離実行なので、ここでの unset は他テストへ波及しない。
  unset BOOCH_INSTALL_REPO
  local log=""
  booch_install_prereqs() { log="$log prereqs"; }
  booch_install_auth()    { log="$log auth"; }
  booch_install_clone()   { log="$log clone"; }
  local rc
  if booch_install_main --dir /tmp/df >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "" "$log" "repo 未指定なら副作用を起こさない"
}
test_install_main_rejects_unknown_arg() {
  local rc; if booch_install_main --bogus >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
test_install_main_help_succeeds() {
  local rc; if booch_install_main --help >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

# --- --booch-ref 未指定（clone したタグの最新へ checkout / タグが無ければ既定ブランチのまま） ---
test_install_ensure_booch_checks_out_latest_tag_when_ref_empty() {
  local d; d=$(mktemp -d); mkdir -p "$d/df"
  local cap_checkout=""
  booch_install_git() {
    case "$*" in
      *" tag --list "*) printf 'v1.13.2\nv1.9.0\n' ;;
      *checkout*) cap_checkout="$*" ;;
    esac
    return 0
  }
  booch_install_ensure_booch "$d/df" "" >/dev/null
  assert_contains "$cap_checkout" "checkout v1.13.2"
  rm -rf "$d"
}
test_install_ensure_booch_stays_on_default_branch_without_tags() {
  local d; d=$(mktemp -d); mkdir -p "$d/df"
  local cap_checkout=""
  booch_install_git() { case "$*" in *checkout*) cap_checkout="$*" ;; esac; return 0; }
  booch_install_ensure_booch "$d/df" "" >/dev/null 2>&1
  assert_eq "" "$cap_checkout" "タグが無ければ checkout しない"
  rm -rf "$d"
}

# --- gh の keyring の fingerprint 照合（#23） ---
# gpg --show-keys --with-colons の形。主鍵の fpr は pub の直後、副鍵の fpr は sub の直後。
_gh_records() { # 主鍵の fingerprint...
  local f
  for f in "$@"; do
    printf 'pub:-:4096:1:%s:1::::::sc::::::23::0:\nfpr:::::::::%s:\n' "${f: -16}" "$f"
    printf 'sub:-:4096:1:0000000000000000:1::::::e::::::23:\nfpr:::::::::SUBKEY%s:\n' "${f: -16}"
  done
}
test_install_verify_gh_keyring_accepts_pinned_keys() {
  booch_install_gh_key_records() { _gh_records "${_BI_GH_KEY_FPRS[@]}"; }
  local rc; if booch_install_verify_gh_keyring kr 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc" "副鍵の fingerprint は照合しない"
}
test_install_verify_gh_keyring_accepts_subset_of_pinned_keys() {
  booch_install_gh_key_records() { _gh_records "${_BI_GH_KEY_FPRS[1]}"; }
  local rc; if booch_install_verify_gh_keyring kr 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc" "上流が古い鍵を外しても通す"
}
test_install_verify_gh_keyring_ignores_caller_ifs() {
  booch_install_gh_key_records() { _gh_records "${_BI_GH_KEY_FPRS[@]}"; }
  local rc; if IFS=$'\n\t' booch_install_verify_gh_keyring kr 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc" "呼び出し側の IFS で照合が変わらない"
}
test_install_verify_gh_keyring_rejects_extra_key() {
  booch_install_gh_key_records() { _gh_records "${_BI_GH_KEY_FPRS[@]}" AAAABBBBCCCCDDDDEEEEFFFF0000111122223333; }
  local rc err; err=$(booch_install_verify_gh_keyring kr 2>&1) && rc=0 || rc=$?
  assert_status 1 "$rc" "固定した鍵に足された鍵があれば落とす"
  assert_contains "$err" "AAAABBBBCCCCDDDDEEEEFFFF0000111122223333"
}
test_install_verify_gh_keyring_rejects_empty_keyring() {
  booch_install_gh_key_records() { :; }
  local rc; if booch_install_verify_gh_keyring kr 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc" "鍵が 1 本も無ければ落とす"
}
test_install_verify_gh_keyring_rejects_unreadable_keyring() {
  booch_install_gh_key_records() { return 2; }
  local rc; if booch_install_verify_gh_keyring kr 2>/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
test_install_ensure_gh_repo_does_not_place_keyring_on_mismatch() {
  local d; d=$(mktemp -d)
  _BI_GH_KEYRING="$d/keyrings/gh.gpg"; _BI_GH_LIST="$d/gh.list"
  # deb 行の sudo tee はパイプの先（サブシェル）で呼ばれるので、記録はファイルに取る。
  sudo() { echo "$*" >> "$d/sudo.log"; }
  dpkg() { echo amd64; }
  booch_install_fetch_gh_keyring() { : > "$1"; }
  booch_install_verify_gh_keyring() { return 1; }
  local rc; if booch_install_ensure_gh_repo >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_eq "" "$(cat "$d/sudo.log" 2>/dev/null)" "照合に落ちたら keyring も deb 行も置かない"
  rm -rf "$d"
}
test_install_ensure_gh_repo_places_verified_keyring() {
  local d; d=$(mktemp -d)
  _BI_GH_KEYRING="$d/keyrings/gh.gpg"; _BI_GH_LIST="$d/gh.list"
  local cap verified=""
  sudo() { echo "$*" >> "$d/sudo.log"; }   # 記録をファイルに取る理由は上のテストと同じ
  dpkg() { echo amd64; }
  booch_install_fetch_gh_keyring() { : > "$1"; }
  booch_install_verify_gh_keyring() { verified=$1; }
  booch_install_ensure_gh_repo >/dev/null 2>&1
  cap=$(cat "$d/sudo.log")
  assert_contains "$cap" "install -m 0644 $verified $d/keyrings/gh.gpg" "照合したファイルを置く"
  assert_contains "$cap" "tee $d/gh.list"
  assert_file_absent "$verified" "一時ファイルを消す"
  rm -rf "$d"
}
test_install_prereqs_installs_gpg_with_gh() {
  local cap=""
  _bi_have() { [ "$1" = git ] || [ "$1" = curl ]; }   # gh / gpg が無い
  booch_install_apt() { case "$1" in install) cap="$*" ;; esac; }
  booch_install_ensure_gh_repo() { return 1; }
  booch_install_prereqs >/dev/null 2>&1 || true
  assert_eq "install -y gpg" "$cap" "gh を入れるときは照合用の gpg も入れる"
}

run_tests
