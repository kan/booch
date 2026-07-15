#!/usr/bin/env bash
# lib/cleanup.sh のユニットテスト。docker / disk seam をスタブして検証する。

# stub は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317
TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/cleanup.sh
source "$BOOCH_ROOT/lib/cleanup.sh"

# --- booch_cleanup_run ---
test_cleanup_run_shows_and_indents() {
  local out; out=$(booch_cleanup_run echo hello)
  assert_contains "$out" '$ echo hello'
  assert_contains "$out" '    hello'   # 出力は 4 スペースでインデント
}

test_cleanup_run_tolerates_failure() {
  local rc; if booch_cleanup_run false >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"   # 失敗しても 0
}

# --- booch_cleanup_report_freed（disk avail を seam で固定） ---
test_report_freed_positive() {
  booch_cleanup_disk_avail() { echo 2048; }   # after
  assert_contains "$(booch_cleanup_report_freed 1024)" "Freed:"
}

test_report_freed_handles_nonnumeric_before() {
  booch_cleanup_disk_avail() { echo 1000; }
  # before が非数値でも 0 扱いで落ちない
  assert_contains "$(booch_cleanup_report_freed "")" "Freed:"
}

test_report_freed_negative_uses_minus() {
  booch_cleanup_disk_avail() { echo 100; }    # after < before → 負
  assert_contains "$(booch_cleanup_report_freed 1000)" "-"
}

# --- booch_cleanup_docker_prune_safe ---
test_docker_prune_skips_when_unavailable() {
  command() { return 1; }   # docker 不在
  assert_contains "$(booch_cleanup_docker_prune_safe)" "docker unavailable"
}

test_docker_prune_runs_prunes_when_available() {
  # docker available（command -v docker / docker info を通す）
  command() { case "$2" in docker) return 0 ;; *) builtin command "$@" ;; esac; }
  docker() { case "$1" in info) return 0 ;; system) echo "df"; ;; *) echo "docker $*" ;; esac; }
  sh() { :; }   # network 削除ループは no-op
  local out; out=$(booch_cleanup_docker_prune_safe common)
  assert_contains "$out" "docker container prune"
  assert_contains "$out" "docker image prune"
}

# with_builder=builder でビルドキャッシュ prune も走る。
test_docker_prune_with_builder() {
  command() { case "$2" in docker) return 0 ;; *) builtin command "$@" ;; esac; }
  docker() { case "$1" in info) return 0 ;; *) echo "docker $*" ;; esac; }
  sh() { :; }
  local out; out=$(booch_cleanup_docker_prune_safe common builder)
  assert_contains "$out" "docker builder prune"
}

# --- booch_cleanup_worktree_prune ---
# 実体が消えた worktree の登録メタだけを prune する（実在 worktree は消さない）。
test_worktree_prune_removes_stale_registration() {
  local d; d=$(mktemp -d)
  git init -q "$d/repo"
  ( cd "$d/repo" \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
      && git worktree add -q "$d/wt" >/dev/null 2>&1 )
  rm -rf "$d/wt"   # 実体を消す（登録メタは残り prunable になる）
  local before after
  before=$(git -C "$d/repo" worktree list | wc -l)
  booch_cleanup_worktree_prune "$d/repo" >/dev/null 2>&1
  after=$(git -C "$d/repo" worktree list | wc -l)
  assert_eq "2" "$before"   # prune 前: 本体 + 消えた wt の登録
  assert_eq "1" "$after"    # prune 後: 本体のみ
  rm -rf "$d"
}

# 非 git / 不在パスはスキップして 0（エラーにしない）。
test_worktree_prune_skips_non_git() {
  local d; d=$(mktemp -d)
  local rc; if booch_cleanup_worktree_prune "$d/not-a-repo" /nonexistent >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  rm -rf "$d"
}

run_tests
