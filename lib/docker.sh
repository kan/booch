#!/usr/bin/env bash
# Docker の post-install（グループ・デーモン）。Docker を入れる利用側で共通に欲しい後処理。
# Docker を入れるか・systemd 前提かは利用側が決める（本関数は docker があるときだけ動く）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/docker.sh"
#   booch_docker_post_install            # $USER を docker グループへ
#   booch_docker_post_install someuser
#
# 依存: docker（存在チェック）, sudo, groupadd, usermod, systemctl, id, grep。

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
