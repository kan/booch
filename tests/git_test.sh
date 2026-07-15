#!/usr/bin/env bash
# lib/git.sh のユニットテスト。git コマンドと seam をスタブで差し替え、実リポジトリ無しで
# 分岐を検証する。

# stub（git / seam）は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317,SC2329
TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/git.sh
source "$BOOCH_ROOT/lib/git.sh"

# git をスタブする。テスト変数で挙動を制御:
#   _G_BRANCH（rev-parse の出力） / _G_DIRTY（status --porcelain の出力） /
#   _G_PULL_OUT（pull の出力） / _G_PULL_RC（pull の戻り値） /
#   _G_FETCH_RC（fetch の戻り値） / _G_COUNTS（rev-list の出力 "ahead behind"）
_stub_git() {
  # timeout は外部コマンドで、そのままだと git 関数スタブをバイパスして実 git を呼ぶ。
  # 期間引数を捨てて後続コマンド（git ...）へ委譲し、スタブが効くようにする。
  timeout() { shift; "$@"; }
  git() {
    local sub
    # "-C dir <sub> ..." の <sub> を取る
    if [ "$1" = "-C" ]; then sub=$3; else sub=$1; fi
    case "$sub" in
      rev-parse) printf '%s' "${_G_BRANCH:-main}" ;;
      status) printf '%s' "${_G_DIRTY:-}" ;;
      pull) printf '%s' "${_G_PULL_OUT:-}"; return "${_G_PULL_RC:-0}" ;;
      fetch) return "${_G_FETCH_RC:-0}" ;;
      rev-list) printf '%s' "${_G_COUNTS:-0 0}" ;;
      *) return 0 ;;
    esac
  }
}

# --- booch_git_pull_ff_clean（repo は存在扱いにするため .git ありの temp を使う） ---
_mk_repo() { local d; d=$(mktemp -d); mkdir -p "$d/.git"; printf '%s' "$d"; }

test_pull_ff_up_to_date() {
  _stub_git; _G_BRANCH=main; _G_DIRTY=""; _G_PULL_OUT="Already up to date."; _G_PULL_RC=0
  local d; d=$(_mk_repo)
  assert_contains "$(booch_git_pull_ff_clean "$d" master,main,develop)" "up to date"
  rm -rf "$d"
}

test_pull_ff_updated() {
  _stub_git; _G_BRANCH=main; _G_DIRTY=""; _G_PULL_OUT="Updating abc..def"; _G_PULL_RC=0
  local d; d=$(_mk_repo)
  assert_contains "$(booch_git_pull_ff_clean "$d")" "updated"
  rm -rf "$d"
}

test_pull_ff_skips_disallowed_branch() {
  _stub_git; _G_BRANCH=feature-x
  local d; d=$(_mk_repo)
  assert_contains "$(booch_git_pull_ff_clean "$d" master,main,develop)" "[SKIP]"
  rm -rf "$d"
}

test_pull_ff_warns_on_dirty() {
  _stub_git; _G_BRANCH=main; _G_DIRTY=" M file.txt"
  local d; d=$(_mk_repo)
  assert_contains "$(booch_git_pull_ff_clean "$d")" "local changes"
  rm -rf "$d"
}

test_pull_ff_warns_on_pull_failure() {
  _stub_git; _G_BRANCH=main; _G_DIRTY=""; _G_PULL_OUT="fatal: not possible"; _G_PULL_RC=1
  local d; d=$(_mk_repo)
  assert_contains "$(booch_git_pull_ff_clean "$d")" "pull failed"
  rm -rf "$d"
}

test_pull_ff_not_a_repo() {
  local d; d=$(mktemp -d)   # .git なし
  assert_contains "$(booch_git_pull_ff_clean "$d")" "not a git repo"
  rm -rf "$d"
}

# --- booch_git_pull_repos ---
test_pull_repos_reports_none_when_empty() {
  local base; base=$(mktemp -d)
  assert_contains "$(booch_git_pull_repos "$base" main nonexistent)" "no target repositories"
  rm -rf "$base"
}

test_pull_repos_labels_and_pulls() {
  _stub_git; _G_BRANCH=main; _G_DIRTY=""; _G_PULL_OUT="Already up to date."; _G_PULL_RC=0
  local base; base=$(mktemp -d); mkdir -p "$base/proj-a/.git"
  local out; out=$(booch_git_pull_repos "$base" main proj-a)
  assert_contains "$out" "proj-a"
  assert_contains "$out" "up to date"
  rm -rf "$base"
}

# --- booch_git_self_update ---
test_self_update_up_to_date() {
  _stub_git; _G_FETCH_RC=0; _G_COUNTS="0 0"
  local d; d=$(_mk_repo)
  assert_contains "$(booch_git_self_update "$d" true)" "Up to date"
  rm -rf "$d"
}

test_self_update_diverged() {
  _stub_git; _G_FETCH_RC=0; _G_COUNTS="2 3"
  local d; d=$(_mk_repo)
  assert_contains "$(booch_git_self_update "$d" true)" "Diverged"
  rm -rf "$d"
}

test_self_update_ahead() {
  _stub_git; _G_FETCH_RC=0; _G_COUNTS="2 0"
  local d; d=$(_mk_repo)
  assert_contains "$(booch_git_self_update "$d" true)" "ahead"
  rm -rf "$d"
}

# 更新ありだが確認 no → pull/再実行しない。
test_self_update_behind_declined() {
  _stub_git; _G_FETCH_RC=0; _G_COUNTS="0 1"
  booch_git_self_update_confirm() { return 1; }
  local reexec=0; booch_git_reexec() { reexec=1; }
  local d; d=$(_mk_repo)
  local out; out=$(booch_git_self_update "$d" true)
  assert_contains "$out" "update(s) available"
  assert_eq "0" "$reexec" "確認 no では再実行しない"
  rm -rf "$d"
}

# 更新ありで確認 yes → 再実行 seam が呼ばれる。
test_self_update_behind_accepted_reexecs() {
  _stub_git; _G_FETCH_RC=0; _G_COUNTS="0 1"
  booch_git_self_update_confirm() { return 0; }
  local reexec=0; booch_git_reexec() { reexec=1; }
  local d; d=$(_mk_repo)
  booch_git_self_update "$d" true >/dev/null
  assert_eq "1" "$reexec" "確認 yes で再実行 seam を呼ぶ"
  rm -rf "$d"
}

# 更新ありで確認 yes でも pull が失敗したら再実行しない（古いコードで「最新」と誤報しない）。
test_self_update_behind_pull_failure_no_reexec() {
  _stub_git; _G_FETCH_RC=0; _G_COUNTS="0 1"; _G_PULL_RC=1
  booch_git_self_update_confirm() { return 0; }
  local reexec=0; booch_git_reexec() { reexec=1; }
  local d; d=$(_mk_repo)
  local out; out=$(booch_git_self_update "$d" true 2>&1)
  assert_eq "0" "$reexec" "pull 失敗時は再実行しない"
  assert_contains "$out" "pull failed"
  rm -rf "$d"
}

# 上流追跡ブランチが無ければ「Up to date」と誤報せず skip する。
# shellcheck disable=SC2317,SC2329  # git スタブは間接呼び出し
test_self_update_no_upstream_skips() {
  _stub_git; _G_FETCH_RC=0
  git() {   # @{u} 解決だけ失敗させる（上流未設定を再現）
    local sub; if [ "$1" = "-C" ]; then sub=$3; else sub=$1; fi
    case "$sub" in
      fetch) return 0 ;;
      rev-parse) case "$*" in *'@{u}'*) return 1 ;; *) printf 'main' ;; esac ;;
      *) return 0 ;;
    esac
  }
  local d; d=$(_mk_repo)
  assert_contains "$(booch_git_self_update "$d" true)" "No upstream"
  rm -rf "$d"
}

# fetch 失敗は exit 1 で中断する（サブシェルで捕捉）。
test_self_update_fetch_failure_aborts() {
  _stub_git; _G_FETCH_RC=1
  local d; d=$(_mk_repo)
  local rc; if ( booch_git_self_update "$d" true ) >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  rm -rf "$d"
}

run_tests
