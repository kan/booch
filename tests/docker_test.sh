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

# --- booch_docker_daemon_config_ensure ---
# 実ファイルを temp に置き、検証（dockerd）と配置（sudo install）は seam で差し替える。
_setup_daemon_config() { # initial_json
  BOOCH_DOCKER_DAEMON_CONFIG=$(mktemp)
  printf '%s\n' "$1" >"$BOOCH_DOCKER_DAEMON_CONFIG"
  BOOCH_DOCKER_DAEMON_CONFIG_CHANGED=0
  booch_docker_daemon_config_validate() { return 0; }
  booch_docker_daemon_config_write() { cat "$1" >"$BOOCH_DOCKER_DAEMON_CONFIG"; }
}

test_daemon_config_noop_when_already_applied() {
  _setup_daemon_config '{"builder":{"gc":{"enabled":true}}}'
  local out; out=$(booch_docker_daemon_config_ensure '{"builder":{"gc":{"enabled":true}}}')
  assert_contains "$out" "最新です"
  assert_eq "0" "$BOOCH_DOCKER_DAEMON_CONFIG_CHANGED"
  rm -f "$BOOCH_DOCKER_DAEMON_CONFIG"
}

# 渡したキーだけ更新し、利用者が足した他キーは残す。
test_daemon_config_merges_and_keeps_other_keys() {
  _setup_daemon_config '{"log-driver":"json-file","builder":{"gc":{"enabled":true}}}'
  booch_docker_daemon_config_ensure '{"builder":{"gc":{"policy":[{"maxUsedSpace":"20GB"}]}}}' >/dev/null
  assert_eq "1" "$BOOCH_DOCKER_DAEMON_CONFIG_CHANGED"
  local got; got=$(cat "$BOOCH_DOCKER_DAEMON_CONFIG")
  assert_contains "$got" "json-file"     # 他キーは温存
  assert_contains "$got" "maxUsedSpace"  # 渡したキーは反映
  assert_contains "$got" "enabled"       # 既存の同ブロックも温存
  rm -f "$BOOCH_DOCKER_DAEMON_CONFIG"
}

# post filter で旧キーを落とせる（マージだけでは消せないため）。
test_daemon_config_post_filter_deletes_obsolete_key() {
  _setup_daemon_config '{"builder":{"gc":{"defaultKeepStorage":"10GB"}}}'
  booch_docker_daemon_config_ensure \
    '{"builder":{"gc":{"enabled":true}}}' 'del(.builder.gc.defaultKeepStorage)' >/dev/null
  local got; got=$(cat "$BOOCH_DOCKER_DAEMON_CONFIG")
  assert_not_contains "$got" "defaultKeepStorage"
  rm -f "$BOOCH_DOCKER_DAEMON_CONFIG"
}

# 既存が壊れた JSON なら触らない（手編集を捨てない）。
test_daemon_config_keeps_broken_json() {
  _setup_daemon_config '{ this is not json'
  local rc out
  if out=$(booch_docker_daemon_config_ensure '{"a":1}'); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "JSON として読めない"
  assert_contains "$(cat "$BOOCH_DOCKER_DAEMON_CONFIG")" "this is not json"
  rm -f "$BOOCH_DOCKER_DAEMON_CONFIG"
}

# dockerd が受け付けない設定は書かない（起動不能を作らない）。
test_daemon_config_rejects_invalid_config() {
  _setup_daemon_config '{"log-driver":"json-file"}'
  booch_docker_daemon_config_validate() { return 1; }
  local rc out
  if out=$(booch_docker_daemon_config_ensure '{"bogus":true}'); then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_contains "$out" "受け付けませんでした"
  assert_not_contains "$(cat "$BOOCH_DOCKER_DAEMON_CONFIG")" "bogus"
  assert_eq "0" "$BOOCH_DOCKER_DAEMON_CONFIG_CHANGED"
  rm -f "$BOOCH_DOCKER_DAEMON_CONFIG"
}

# --- booch_docker_daemon_restart_if_idle ---
test_restart_noop_without_change() {
  BOOCH_DOCKER_DAEMON_CONFIG_CHANGED=0
  local called=0
  sudo() { called=1; }
  booch_docker_daemon_restart_if_idle
  assert_eq "0" "$called"
}

# 稼働中コンテナがあるときは再起動せず案内だけ（作業中のスタックを落とさない）。
test_restart_defers_when_containers_running() {
  BOOCH_DOCKER_DAEMON_CONFIG_CHANGED=1
  booch_docker_has_systemd() { return 0; }
  booch_docker_daemon_running_containers() { echo 3; }
  local called=0
  sudo() { called=1; }
  local out; out=$(booch_docker_daemon_restart_if_idle)
  assert_eq "0" "$called"
  assert_contains "$out" "再起動しません"
}

# 稼働中コンテナが無ければ再起動する。
test_restart_runs_when_idle() {
  BOOCH_DOCKER_DAEMON_CONFIG_CHANGED=1
  booch_docker_has_systemd() { return 0; }
  booch_docker_daemon_running_containers() { echo 0; }
  local calls=""
  sudo() { calls="$calls|$*"; }
  booch_docker_daemon_restart_if_idle >/dev/null
  assert_contains "$calls" "systemctl restart docker"
}

# systemd が無い環境では再起動を試みず案内に留める。
test_restart_defers_without_systemd() {
  BOOCH_DOCKER_DAEMON_CONFIG_CHANGED=1
  booch_docker_has_systemd() { return 1; }
  local called=0
  sudo() { called=1; }
  local out; out=$(booch_docker_daemon_restart_if_idle)
  assert_eq "0" "$called"
  assert_contains "$out" "手動"
}

run_tests
