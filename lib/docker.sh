#!/usr/bin/env bash
# Docker の post-install（グループ・デーモン）と daemon.json のキー単位更新。Docker を入れる
# 利用側で共通に欲しい後処理。Docker を入れるか・systemd 前提か・どの設定値にするかは
# 利用側が決める（本関数群は docker があるときだけ動く）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/docker.sh"
#   booch_docker_post_install            # $USER を docker グループへ
#   booch_docker_post_install someuser
#   # daemon.json を「渡したキーだけ」更新する（他キーは温存。変更時のみ書く）
#   booch_docker_daemon_config_ensure '{"builder":{"gc":{"enabled":true}}}'
#   booch_docker_daemon_restart_if_idle  # 変更があり、かつ稼働コンテナが無ければ再起動
#
# daemon.json の実体パスは BOOCH_DOCKER_DAEMON_CONFIG（既定 /etc/docker/daemon.json）で
# 差し替えられる（テスト・非標準配置用）。更新の有無は BOOCH_DOCKER_DAEMON_CONFIG_CHANGED
# （0/1）に載る。
#
# 依存: docker（存在チェック）, sudo, groupadd, usermod, systemctl, id, grep, jq（daemon.json）。
#
# テスト用の継ぎ目（seam）:
#   booch_docker_daemon_config_validate FILE   dockerd --validate（設定の妥当性確認）
#   booch_docker_daemon_config_write FILE      所定パスへの配置（sudo install）
#   booch_docker_daemon_running_containers     稼働中コンテナ数
#   booch_docker_has_systemd                   systemctl で再起動できる環境か

: "${BOOCH_DOCKER_DAEMON_CONFIG:=/etc/docker/daemon.json}"
BOOCH_DOCKER_DAEMON_CONFIG_CHANGED=0

# docker グループを作りユーザーを追加、systemd があればデーモンを有効化・起動する。
# 現セッションにグループが未反映なら再ログインを促す。docker 不在なら何もしない。
#   booch_docker_post_install [user]   user 既定は $USER（無ければ id -un）
booch_docker_post_install() {
  local user=${1:-${USER:-$(id -un)}}
  command -v docker >/dev/null 2>&1 || return 0
  sudo groupadd docker 2>/dev/null || true
  sudo usermod -aG docker "$user"
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  fi
  # 現プロセスのグループ（DB ではなくセッション）に docker が無ければ再ログインが要る。
  if ! id -nG 2>/dev/null | grep -qw docker; then
    echo "  docker group not active in this session; re-login (or 'newgrp docker') required."
  fi
}

# dockerd に設定ファイルの妥当性を確認させる（起動はしない）。dockerd 不在なら検証を省いて
# 通す（docker CLI のみの環境で更新を止めないため）。
booch_docker_daemon_config_validate() { # file
  command -v dockerd >/dev/null 2>&1 || return 0
  sudo dockerd --validate --config-file "$1" >/dev/null 2>&1
}

# 検証済みの一時ファイルを daemon.json の位置へ配置する（親ディレクトリごと作る）。
booch_docker_daemon_config_write() { # file
  sudo install -D -m 0644 "$1" "$BOOCH_DOCKER_DAEMON_CONFIG"
}

# 稼働中コンテナ数を返す（daemon 再起動の可否判断に使う）。
booch_docker_daemon_running_containers() {
  docker ps -q 2>/dev/null | grep -c . || true
}

# systemd 環境か（デーモンを systemctl で再起動できるか）。
booch_docker_has_systemd() {
  [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

# daemon.json を「渡したキーだけ」更新する（丸ごと上書きせず、利用者が足した他キーは残す）。
# json_fragment: マージする JSON オブジェクト。jq の `*`（再帰マージ）なので、配列値は
#   置き換え、オブジェクトは深くマージされる。
# jq_post_filter: マージ後に適用する追加 jq フィルタ（既定 '.'）。旧キーの削除など
#   マージだけでは表現できない整理に使う（例: 'del(.builder.gc.defaultKeepStorage)'）。
# 差分が無ければ何も書かない（冪等）。書く前に dockerd --validate を通し、失敗したら
# 現行設定を残したまま 1 を返す（壊れた設定でデーモンを起動不能にしないため）。
# 実際に書いたときだけ BOOCH_DOCKER_DAEMON_CONFIG_CHANGED=1 にする（再起動は別関数）。
booch_docker_daemon_config_ensure() { # json_fragment [jq_post_filter]
  local fragment=$1 post=${2:-.}
  command -v docker >/dev/null 2>&1 || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "  jq が無いため daemon.json の更新をスキップします"
    return 0
  fi

  local cfg=$BOOCH_DOCKER_DAEMON_CONFIG current merged
  if [ -f "$cfg" ]; then
    if [ -r "$cfg" ]; then current=$(cat "$cfg"); else current=$(sudo cat "$cfg"); fi
  else
    current='{}'
  fi
  # 既存が壊れた JSON なら触らない（利用者の手編集を勝手に捨てない）。
  if ! printf '%s' "$current" | jq -e . >/dev/null 2>&1; then
    echo "  $cfg が JSON として読めないため更新をスキップします（手で確認してください）"
    return 1
  fi

  merged=$(printf '%s' "$current" \
    | jq -S --argjson frag "$fragment" ". * \$frag | $post") || {
    echo "  daemon.json のマージに失敗しました（jq フィルタを確認してください）"
    return 1
  }
  if [ "$(printf '%s' "$current" | jq -S .)" = "$merged" ]; then
    echo "  $cfg は最新です"
    return 0
  fi

  local tmp; tmp=$(mktemp) || return 1
  printf '%s\n' "$merged" >"$tmp"
  if ! booch_docker_daemon_config_validate "$tmp"; then
    rm -f "$tmp"
    echo "  dockerd が新しい $cfg を受け付けませんでした（現行設定のまま）"
    return 1
  fi
  booch_docker_daemon_config_write "$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  BOOCH_DOCKER_DAEMON_CONFIG_CHANGED=1
  echo "  $cfg を更新しました（反映には docker デーモンの再起動が必要）"
}

# daemon.json を更新したときだけ docker を再起動する。再起動は稼働中コンテナを落とすため、
# 1 つでも動いていれば再起動せず案内に留める（日々の setup で作業中のスタックを殺さない）。
booch_docker_daemon_restart_if_idle() {
  [ "$BOOCH_DOCKER_DAEMON_CONFIG_CHANGED" = 1 ] || return 0
  if ! booch_docker_has_systemd; then
    echo "  systemd が無いため再起動は手動で行ってください"
    return 0
  fi
  local running; running=$(booch_docker_daemon_running_containers)
  if [ "${running:-0}" -gt 0 ] 2>/dev/null; then
    echo "  稼働中コンテナが ${running} 個あるため再起動しません（反映: 'sudo systemctl restart docker'）"
    return 0
  fi
  sudo systemctl restart docker && echo "  docker デーモンを再起動しました"
}
