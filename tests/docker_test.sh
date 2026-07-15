#!/usr/bin/env bash
# lib/docker.sh のユニットテスト。docker/sudo/id/systemctl をスタブして検証する。

# stub は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317,SC2329
TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/docker.sh
source "$BOOCH_ROOT/lib/docker.sh"

test_post_install_noop_when_docker_absent() {
  command() { return 1; }   # docker 不在
  local sudo_called=0
  sudo() { sudo_called=1; }
  booch_docker_post_install testuser
  assert_eq "0" "$sudo_called" "docker 不在なら sudo を呼ばない"
}

test_post_install_adds_group_and_user() {
  command() { case "$2" in docker | systemctl) return 0 ;; *) builtin command "$@" ;; esac; }
  local calls=""
  sudo() { calls="$calls|$*"; }
  id() { echo "testuser docker"; }   # 既にグループ反映済み → 再ログイン案内なし
  booch_docker_post_install testuser
  assert_contains "$calls" "groupadd docker"
  assert_contains "$calls" "usermod -aG docker testuser"
}

test_post_install_prompts_relogin_when_group_inactive() {
  command() { case "$2" in docker | systemctl) return 0 ;; *) builtin command "$@" ;; esac; }
  sudo() { :; }
  id() { echo "testuser"; }   # docker グループが現セッションに無い
  local out; out=$(booch_docker_post_install testuser)
  assert_contains "$out" "re-login"
}

test_post_install_no_relogin_when_group_active() {
  command() { case "$2" in docker | systemctl) return 0 ;; *) builtin command "$@" ;; esac; }
  sudo() { :; }
  id() { echo "testuser docker"; }
  local out; out=$(booch_docker_post_install testuser)
  assert_not_contains "$out" "re-login"
}

run_tests
