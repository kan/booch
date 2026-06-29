#!/usr/bin/env bash
# install.sh のユニットテスト。BOOCH_INSTALL_NO_RUN=1 で関数定義だけ読み込み、副作用の
# 継ぎ目（apt / gh / git / exec）をスタブして network / sudo / 実行なしで分岐を検証する。
# 実地スモーク（clean 環境での curl|bash）は別途。

# スタブ（seam）は間接呼び出しで SC2317 に見えるため抑制する。
# shellcheck disable=SC2317

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
  booch_install_clone kan/dotfiles "$d/df" >/dev/null
  assert_eq "repo clone kan/dotfiles $d/df" "$cap"
  rm -rf "$d"
}
test_install_clone_pulls_when_present() {
  local d; d=$(mktemp -d); mkdir -p "$d/df/.git"
  local cap=""
  booch_install_git() { cap="$*"; }
  booch_install_clone kan/dotfiles "$d/df" >/dev/null
  assert_eq "-C $d/df pull --ff-only" "$cap"
  rm -rf "$d"
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
test_install_main_rejects_unknown_arg() {
  local rc; if booch_install_main --bogus >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
test_install_main_help_succeeds() {
  local rc; if booch_install_main --help >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

run_tests
