#!/usr/bin/env bash
# クリーンアップの汎用フレーム。コマンドを表示して実行（出力インデント）、ルートFSの空き
# 容量の前後差分表示、docker の安全な prune。何を消すか（apt/go/npm キャッシュ・light/full
# モード・除外ネットワーク）は利用側が決める。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/cleanup.sh"
#   before=$(booch_cleanup_disk_avail)
#   booch_cleanup_run sudo apt-get autoremove -y
#   booch_cleanup_docker_prune_safe common builder
#   booch_cleanup_report_freed "$before"
#
# 依存: df, sed, tr, numfmt, docker（prune 時）。色は lib/color.sh（未定義でも空で動く）。
#
# テスト用の継ぎ目（seam）:
#   booch_cleanup_disk_avail   ルートFSの空き KB（report_freed が after に使う）

: "${_BOOCH_COLOR_YELLOW:=}" "${_BOOCH_COLOR_RESET:=}"

# コマンドを表示してから実行し、出力をインデントする。失敗しても止めない。
booch_cleanup_run() { # cmd...
  printf '  %s$ %s%s\n' "$_BOOCH_COLOR_YELLOW" "$*" "$_BOOCH_COLOR_RESET"
  "$@" 2>&1 | sed 's/^/    /' || true
}

# ルートFSの空き容量（KB）。
booch_cleanup_disk_avail() {
  df -k --output=avail / 2>/dev/null | tail -1 | tr -d ' '
}

# KB 値を人間可読（base-1024、df -h と同等）に整形する。numfmt 不在時は K 表記。
_booch_cleanup_iec() { numfmt --to=iec $(($1 * 1024)) 2>/dev/null || echo "${1}K"; }

# before（booch_cleanup_disk_avail の戻り値）からの解放容量を表示する。空き表示は after を
# 再利用する（2 度目の df を打たず、Freed 値と同じ計測に揃える）。
booch_cleanup_report_freed() { # before_kb
  local before=$1 after freed_kb sign="" abs
  after=$(booch_cleanup_disk_avail)
  case "$before" in '' | *[!0-9]*) before=0 ;; esac
  case "$after" in '' | *[!0-9]*) after=0 ;; esac
  freed_kb=$((after - before))
  abs=$freed_kb
  [ "$freed_kb" -lt 0 ] && { sign="-"; abs=$((-freed_kb)); }
  printf 'Freed: %s%s (/ now has %s available)\n' \
    "$sign" "$(_booch_cleanup_iec "$abs")" "$(_booch_cleanup_iec "$after")"
}

# docker の安全な prune（停止コンテナ・dangling イメージ・接続数 0 のネットワーク）。
# excluded_networks_regex: 既定ネット（bridge|host|none）に加えて除外するネットワーク名の
#   grep -vxE パターン（例: common）。with_builder に builder を渡すとビルドキャッシュも削除。
# docker 不在/未起動なら何もしない。DB volume や未使用タグ付きイメージは自動削除しない。
booch_cleanup_docker_prune_safe() { # [excluded_networks_regex] [with_builder]
  local excl=${1:-} with=${2:-}
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "  (docker unavailable, skip)"
    return 0
  fi
  local netfilter="bridge|host|none"
  [ -n "$excl" ] && netfilter="${excl}|${netfilter}"
  booch_cleanup_run docker container prune -f
  booch_cleanup_run docker image prune -f
  # 接続数 0 のネットワークだけ個別削除する。展開は sh -c の中で行わせる（single quote 意図的）。
  # shellcheck disable=SC2016
  booch_cleanup_run sh -c 'for net in $(docker network ls --format "{{.Name}}" | grep -vxE "'"$netfilter"'"); do [ "$(docker network inspect -f "{{len .Containers}}" "$net" 2>/dev/null)" = "0" ] && docker network rm "$net"; done'
  [ "$with" = builder ] && booch_cleanup_run docker builder prune -f
  echo "  docker disk usage:"
  docker system df 2>/dev/null | sed 's/^/    /'
  echo "  hint: unused tagged images -> 'docker image prune -af'; unused volumes (DBs! careful) -> 'docker volume prune -f'"
}

# 指定した各 git repo で `git worktree prune` を回す。実体が消えた worktree の登録メタだけを
# 掃除する（冪等・安全。実在する worktree は消さない）。非 git / 不在パスはスキップ。表示は
# booch_cleanup_run でインデントする。何の repo を対象にするかは利用側が決める。
booch_cleanup_worktree_prune() { # repo...
  local repo
  for repo in "$@"; do
    [ -e "$repo/.git" ] || continue
    booch_cleanup_run git -C "$repo" worktree prune -v
  done
}
