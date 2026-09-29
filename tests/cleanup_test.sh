#!/usr/bin/env bash
# lib/cleanup.sh のユニットテスト。docker / disk seam をスタブして検証する。

# stub は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317,SC2329
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

# --- booch_cleanup_docker_prune_deep ---
test_docker_prune_deep_skips_when_unavailable() {
  command() { return 1; }   # docker 不在
  assert_contains "$(booch_cleanup_docker_prune_deep true)" "docker unavailable"
}

# 確認で no（tty 無しを含む）なら 1 つも prune せず手動手順を案内する。
test_docker_prune_deep_declined_runs_nothing() {
  command() { case "$2" in docker) return 0 ;; *) builtin command "$@" ;; esac; }
  docker() { case "$1" in info) return 0 ;; *) echo "docker $*" ;; esac; }
  booch_confirm_yes_no() { return 1; }
  local out; out=$(booch_cleanup_docker_prune_deep false)
  assert_contains "$out" "見送りました"
  assert_not_contains "$out" '$ docker image prune -af'
}

# 承諾（assume_yes 相当）ならタグ付き未使用イメージとビルドキャッシュを消す。
test_docker_prune_deep_accepted_runs_prunes() {
  command() { case "$2" in docker) return 0 ;; *) builtin command "$@" ;; esac; }
  docker() { case "$1" in info) return 0 ;; *) echo "docker $*" ;; esac; }
  booch_confirm_yes_no() { return 0; }
  local out; out=$(booch_cleanup_docker_prune_deep true)
  assert_contains "$out" "docker builder prune -af"
  assert_contains "$out" "docker image prune -af"
  # volume は自動削除しない（DB データを含みうる）。
  assert_not_contains "$out" "volume prune"
}

# 見込み表示は docker system df の該当セルを使う（取れなければ unknown）。
test_docker_prune_deep_reports_reclaimable() {
  command() { case "$2" in docker) return 0 ;; *) builtin command "$@" ;; esac; }
  docker() { case "$1" in info) return 0 ;; *) echo "docker $*" ;; esac; }
  # 継ぎ目は行まとめ側（df_field も prune_deep もここを通る）。呼び出し回数も数え、
  # 2 セル引くのに docker system df の集計を 2 回走らせないことを固定する。
  # 呼び出し回数はコマンド置換のサブシェルを跨ぐのでファイルで数える。
  local cnt; cnt=$(mktemp)
  booch_cleanup_docker_df_rows() {
    echo x >> "$cnt"
    printf 'Images|52.30GB|44.11GB (69%%)\nBuild Cache|41.51GB|41.51GB (100%%)\n'
  }
  booch_confirm_yes_no() { return 1; }
  local out; out=$(booch_cleanup_docker_prune_deep false)
  assert_contains "$out" "44.11GB"
  assert_contains "$out" "41.51GB"
  assert_eq "1" "$(wc -l < "$cnt")"
  rm -f "$cnt"
}

# --- booch_cleanup_docker_volumes_prune ---
_ANON=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# docker を使える状態にする。`docker volume ls` は $_VOL_DANGLING（既定は 1 件あり）を返し、
# `docker volume rm` に渡った名前は、コマンド置換のサブシェルを跨ぐのでファイル $_VOL_LOG に
# 1 行ずつ書く。$_VOL_LOG はテストのサブシェルを抜けるときに消す。
_docker_volume_available() {
  _VOL_LOG=$(mktemp)
  _VOL_DANGLING=x
  trap 'rm -f "$_VOL_LOG"' EXIT
  command() { case "$2" in docker) return 0 ;; *) builtin command "$@" ;; esac; }
  docker() {
    case "$1 ${2:-}" in
      info*) return 0 ;;
      "volume ls") printf '%s' "$_VOL_DANGLING" ;;
      "volume rm") shift 2; printf '%s\n' "$@" > "$_VOL_LOG" ;;
    esac
  }
}

# 上に加えて、volume 一覧の継ぎ目を匿名 / キャッシュ / DB / 使用中の混在に差し替える。
_volumes_stub() {
  _docker_volume_available
  booch_cleanup_docker_volume_rows() {
    printf '%s\n' \
      "$_ANON|0|73.88MB|com.docker.volume.anonymous=" \
      "labelled-anon|0|1MB|a=b,com.docker.volume.anonymous=" \
      "app_node-modules|0|1.5GB|com.docker.compose.project=app" \
      "app_go-build-cache|0|500MB|" \
      "app_mysql-data|0|232.5MB|com.docker.compose.project=app" \
      "used_node-modules|1|2GB|" \
      "$(printf 'f%.0s' {1..64})|2|10MB|"
  }
  booch_cleanup_docker_volume_created() {
    printf '%s\n' "$_ANON|2026-06-20T11:44:01+09:00" "labelled-anon|2026-09-01T08:00:00+09:00"
  }
}

_removed() { sort "$_VOL_LOG" | tr '\n' ' '; }

test_volumes_prune_skips_when_unavailable() {
  command() { return 1; }
  assert_contains "$(booch_cleanup_docker_volumes_prune true '*node-modules')" "docker unavailable"
}

# 承諾したら、未使用の匿名 volume とパターンに一致する volume だけを消す。
# DB らしき volume と使用中の volume は消さない。
test_volumes_prune_removes_anonymous_and_cache() {
  _volumes_stub
  local out; out=$(booch_cleanup_docker_volumes_prune true '*node-modules' '*[_-]cache')
  assert_eq "$_ANON app_go-build-cache app_node-modules labelled-anon " "$(_removed)"
  assert_contains "$out" "匿名 volume 2 個 74.9MB"
  assert_contains "$out" "名前付き volume 2 個 2.00GB"
  # 残すものは名前と大きさを表示する。
  assert_contains "$out" "残す未使用 volume"
  assert_contains "$out" "app_mysql-data"
  assert_not_contains "$out" "used_node-modules"
}

# orphan: の glob は、compose のプロジェクトが見当たらない volume だけを消す。生きている
# プロジェクトの依存と、見当たらないプロジェクトのデータは残し、後者には注記を付ける。
test_volumes_prune_orphan_only_when_project_gone() {
  _docker_volume_available
  booch_cleanup_docker_volume_rows() {
    printf '%s\n' \
      "live_node-modules|0|1GB|com.docker.compose.project=live,com.docker.compose.volume=node-modules" \
      "tmp-1_e2e-node-modules|0|17MB|com.docker.compose.config-hash=x,com.docker.compose.project=tmp-1" \
      "tmp-1_mysql-data|0|5MB|com.docker.compose.project=tmp-1" \
      "nolabel_node-modules|0|3MB|"
  }
  booch_cleanup_docker_project_alive() { [ "$1" != tmp-1 ]; }
  local out; out=$(booch_cleanup_docker_volumes_prune true 'orphan:*node-modules')
  assert_eq "tmp-1_e2e-node-modules " "$(_removed)"
  assert_contains "$out" "プロジェクト tmp-1 が見当たらない"
  assert_contains "$(grep 'tmp-1_mysql-data' <<<"$out")" "見当たらない"
}

# orphan: を渡したのに探す場所が未設定なら、その旨を出して orphan: の volume は消さない。
test_volumes_prune_orphan_without_roots_warns() {
  _docker_volume_available
  booch_cleanup_docker_volume_rows() { echo "tmp-1_node-modules|0|17MB|com.docker.compose.project=tmp-1"; }
  BOOCH_CLEANUP_PROJECT_ROOTS=
  local out; out=$(booch_cleanup_docker_volumes_prune true 'orphan:*node-modules')
  assert_contains "$out" "BOOCH_CLEANUP_PROJECT_ROOTS が未設定"
  assert_eq "" "$(_removed)"
}

# プロジェクトの生死: 探す場所（glob 可）の直下に同名のディレクトリがあれば生きている。
# 探す場所が未設定なら、消し過ぎないよう生きている扱い。
test_project_alive_searches_roots() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/top" "$d/group/nested" "$d/My.App"
  BOOCH_CLEANUP_PROJECT_ROOTS="$d:$d/*"
  booch_cleanup_docker_project_alive top || fail "直下が見つからない"
  booch_cleanup_docker_project_alive nested || fail "1 段下が見つからない"
  # compose と同じ正規化（小文字化、[a-z0-9_-] 以外の除去）をしたディレクトリ名とも比べる。
  booch_cleanup_docker_project_alive myapp || fail "正規化した名前で見つからない"
  if booch_cleanup_docker_project_alive gone; then fail "無いものを生きていると判定"; fi
  BOOCH_CLEANUP_PROJECT_ROOTS=
  booch_cleanup_docker_project_alive gone || fail "未設定なら生きている扱いのはず"
  rm -rf "$d"
}

# 匿名 volume は短縮 ID / 大きさ / 作成日時を新しい順に出す（どれを消すか判断できるように）。
test_volumes_prune_lists_anonymous_newest_first() {
  _volumes_stub
  booch_confirm_yes_no() { return 1; }
  local out; out=$(booch_cleanup_docker_volumes_prune false)
  assert_contains "$out" "0123456789ab   73.88MB    2026-06-20 11:44"
  local newer older
  newer=$(printf '%s\n' "$out" | grep -n 'labelled-ano' | cut -d: -f1)
  older=$(printf '%s\n' "$out" | grep -n '0123456789ab' | cut -d: -f1)
  [ "$newer" -lt "$older" ] || fail "新しい順になっていない: $out"
}

# パターンを渡さなければ匿名 volume だけが対象で、名前付きは全部残す。
test_volumes_prune_without_patterns_keeps_named() {
  _volumes_stub
  booch_cleanup_docker_volumes_prune true >/dev/null
  assert_eq "$_ANON labelled-anon " "$(_removed)"
}

# 確認で no（tty 無しを含む）なら何も消さない。
test_volumes_prune_declined_removes_nothing() {
  _volumes_stub
  booch_confirm_yes_no() { return 1; }
  local out; out=$(booch_cleanup_docker_volumes_prune false '*node-modules')
  assert_contains "$out" "見送りました"
  assert_eq "" "$(_removed)"
}

# 消せるものが無ければ、残すものだけを出して確認は出さない。
test_volumes_prune_nothing_to_remove() {
  _docker_volume_available
  booch_cleanup_docker_volume_rows() { echo "app_mysql-data|0|1MB|"; }
  booch_confirm_yes_no() { echo "UNEXPECTED confirm"; return 0; }
  local out; out=$(booch_cleanup_docker_volumes_prune false '*node-modules')
  assert_contains "$out" "app_mysql-data"
  assert_contains "$out" "削除できる未使用 volume はありません"
  assert_not_contains "$out" "UNEXPECTED"
  assert_eq "" "$(_removed)"
}

# 未使用 volume が 1 つも無ければ、重い大きさの集計（system df -v）を打たない。
test_volumes_prune_no_dangling_skips_rows() {
  _docker_volume_available
  _VOL_DANGLING=
  booch_cleanup_docker_volume_rows() { echo "UNEXPECTED rows"; }
  local out; out=$(booch_cleanup_docker_volumes_prune true '*node-modules')
  assert_contains "$out" "削除できる未使用 volume はありません"
  assert_not_contains "$out" "UNEXPECTED"
}

test_size_sum_units() {
  assert_eq "1.05GB" "$(printf '%s\n' 1GB 48.88kB 0B 50MB | _booch_cleanup_size_sum)"
  assert_eq "512B" "$(printf '%s\n' 512B | _booch_cleanup_size_sum)"
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
