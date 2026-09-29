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
#   booch_cleanup_docker_prune_deep "$ASSUME_YES"   # 確認付きの深い prune
#   BOOCH_CLEANUP_PROJECT_ROOTS="$HOME:$HOME/*" \
#     booch_cleanup_docker_volumes_prune "$ASSUME_YES" '*[_-]cache' 'orphan:*node-modules'
#                                                   # 確認付きの未使用 volume 削除（匿名 + キャッシュ
#                                                   # + プロジェクトが見当たらない依存）
#   booch_cleanup_report_freed "$before"
#
# 依存: df, sed, tr, numfmt, awk, docker（prune 時）。色は lib/color.sh（未定義でも空で動く）。
# deep prune と volume 削除の確認は lib/confirm.sh（同じ BOOCH_ROOT から読む。無ければ非対話扱い）。
#
# テスト用の継ぎ目（seam）:
#   booch_cleanup_disk_avail          ルートFSの空き KB（report_freed が after に使う）
#   booch_cleanup_docker_df_field     docker system df の 1 セル（deep prune の見込み表示）
#   booch_cleanup_docker_volume_rows  volume ごとの名前 / 参照数 / 大きさ / ラベル（volume 削除の判定）
#   booch_cleanup_docker_volume_created  volume ごとの作成日時（匿名 volume の一覧表示）
#   booch_cleanup_docker_project_alive   compose のプロジェクトの生死（orphan: の判定）

: "${_BOOCH_COLOR_YELLOW:=}" "${_BOOCH_COLOR_RESET:=}"

# 確認プロンプト（booch_confirm_yes_no）を deep prune で使う。単体 source でも動くよう、
# BOOCH_ROOT から取り込めるときだけ読み、無ければ「常に no」の代替を置く（非対話と同じ扱い）。
if ! declare -F booch_confirm_yes_no >/dev/null 2>&1; then
  if [ -n "${BOOCH_ROOT:-}" ] && [ -f "$BOOCH_ROOT/lib/confirm.sh" ]; then
    # shellcheck source=/dev/null
    source "$BOOCH_ROOT/lib/confirm.sh"
  else
    booch_confirm_yes_no() { return 1; }
  fi
fi

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

# docker が使えれば 0。使えなければスキップの旨を表示して 1。
_booch_cleanup_docker_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && return 0
  echo "  (docker unavailable, skip)"
  return 1
}

# docker の安全な prune（停止コンテナ・dangling イメージ・接続数 0 のネットワーク）。
# excluded_networks_regex: 既定ネット（bridge|host|none）に加えて除外するネットワーク名の
#   grep -vxE パターン（例: common）。with_builder に builder を渡すとビルドキャッシュも削除。
# docker 不在/未起動なら何もしない。DB volume や未使用タグ付きイメージは自動削除しない。
booch_cleanup_docker_prune_safe() { # [excluded_networks_regex] [with_builder]
  local excl=${1:-} with=${2:-}
  _booch_cleanup_docker_ready || return 0
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

# docker system df の全行を "Type|Size|Reclaimable" で返す。取得できなければ空。
# テストの継ぎ目でもある。df の集計はイメージ・キャッシュが多いほど重い（数十 GB 規模で
# 数秒〜）ので、セルが 2 つ以上要るときは df_field を並べず これを 1 回呼んで切り出す。
booch_cleanup_docker_df_rows() {
  docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null
}

# docker system df の 1 セルを返す（type は Images / Containers / "Local Volumes" /
# "Build Cache"、field は size / reclaimable）。取得できなければ空。
# 1 セルにつき df を 1 回叩くので、複数セルが要る場合は booch_cleanup_docker_df_rows を使う。
booch_cleanup_docker_df_field() { # type field
  local type=$1 field=$2 col
  case "$field" in
    size)        col=2 ;;
    reclaimable) col=3 ;;
    *) return 0 ;;
  esac
  booch_cleanup_docker_df_rows \
    | awk -F'|' -v t="$type" -v c="$col" '$1 == t { print $c; exit }'
}

# docker の深い prune（未使用タグ付きイメージ + ビルドキャッシュ全体）。安全版
# （booch_cleanup_docker_prune_safe）が残す「どのコンテナからも参照されていないタグ付き
# イメージ」と「使用中でないビルドキャッシュ全部」を回収する。消し過ぎると再取得・再ビルドが
# 走るため、既定で y/N 確認を挟む（tty 無し＝非対話なら見送り）。
# volume は DB データを含みうるので触らない（消せるものを選んで消すのは
# booch_cleanup_docker_volumes_prune）。
booch_cleanup_docker_prune_deep() { # [assume_yes]
  local assume_yes=${1:-false}
  _booch_cleanup_docker_ready || return 0
  # 見込み表示に 2 セル要る。df_field を 2 回呼ぶと重い集計が 2 回走る（deep prune が要る
  # ＝イメージ・キャッシュが肥大した環境ほど遅くなる）ので、1 回取って切り出す。
  local df_rows img_rec cache_size
  df_rows=$(booch_cleanup_docker_df_rows)
  img_rec=$(printf '%s\n' "$df_rows" | awk -F'|' '$1 == "Images" { print $3; exit }')
  cache_size=$(printf '%s\n' "$df_rows" | awk -F'|' '$1 == "Build Cache" { print $2; exit }')
  printf '  回収見込み: 未使用イメージ %s / ビルドキャッシュ %s\n' \
    "${img_rec:-unknown}" "${cache_size:-unknown}"
  if ! booch_confirm_yes_no "  未使用タグ付きイメージとビルドキャッシュを削除しますか?" "$assume_yes"; then
    echo "  見送りました（手動: 'docker builder prune -af' / 'docker image prune -af'）"
    return 0
  fi
  booch_cleanup_run docker builder prune -af
  booch_cleanup_run docker image prune -af
  echo "  docker disk usage:"
  docker system df 2>/dev/null | sed 's/^/    /'
}

# volume ごとに "Name|Links|Size|Labels" を返す（Links はその volume を参照するコンテナ数）。
# 取得できなければ空。テストの継ぎ目。Labels はカンマ区切りなので最後の列に置く。
booch_cleanup_docker_volume_rows() {
  docker system df -v --format '{{range .Volumes}}{{.Name}}|{{.Links}}|{{.Size}}|{{.Labels}}{{println}}{{end}}' 2>/dev/null
}

# 指定した volume ごとに "Name|CreatedAt" を返す（1 回の inspect で引く）。取得できなければ空。
# テストの継ぎ目。匿名 volume はラベルに出どころが残らないので、作成日時を判断材料として見せる。
booch_cleanup_docker_volume_created() { # name...
  [ $# -gt 0 ] || return 0
  docker volume inspect --format '{{.Name}}|{{.CreatedAt}}' "$@" 2>/dev/null
}

# docker の表示サイズ（"73.88MB" / "0B" / "1.946GB" / "48.88kB"。10 進）を stdin から 1 行ずつ
# 読んで合計し、同じ表記で返す。
_booch_cleanup_size_sum() {
  awk '
    {
      n = $0 + 0; u = $0; sub(/^[0-9.]+/, "", u)
      m = 1
      if (u == "kB" || u == "KB") m = 1e3
      else if (u == "MB") m = 1e6
      else if (u == "GB") m = 1e9
      else if (u == "TB") m = 1e12
      s += n * m
    }
    END {
      if (s >= 1e9) printf "%.2fGB\n", s / 1e9
      else if (s >= 1e6) printf "%.1fMB\n", s / 1e6
      else if (s >= 1e3) printf "%.1fkB\n", s / 1e3
      else printf "%dB\n", s
    }'
}

# 名前 → "大きさ" か "大きさ|注記" の連想配列（変数名で受ける）を名前順に表示する。
_booch_cleanup_volume_list() { # assoc_name
  local -n _vl=$1
  local n
  for n in "${!_vl[@]}"; do printf '%s|%s\n' "$n" "${_vl[$n]}"; done \
    | sort | awk -F'|' '{ line = sprintf("    %-50s %-10s %s", $1, $2, $3); sub(/ +$/, "", line); print line }'
}

# name が glob... のどれかに一致すれば 0。
_booch_cleanup_match_any() { # name glob...
  local name=$1 g
  shift
  for g in "$@"; do
    # shellcheck disable=SC2053  # g はパターンとして照合する（意図的に無引用）
    [[ $name == $g ]] && return 0
  done
  return 1
}

# compose のプロジェクトが生きていれば 0。BOOCH_CLEANUP_PROJECT_ROOTS（`:` 区切り。各要素は
# glob として展開する。例: "$HOME:$HOME/*"）のどれかの直下に、プロジェクト名と同じ名前の
# ディレクトリがあれば生きているとみなす（compose は既定でディレクトリ名をプロジェクト名にする）。
# compose はディレクトリ名を小文字にし、[a-z0-9_-] 以外を除いてプロジェクト名にするので
# （~/MyApp → myapp、~/foo.bar → foobar）、ディレクトリ名も同じ規則で正規化して比べる。
# 探す場所が未設定か、プロジェクト名が分からないときは、消し過ぎないよう生きている扱いにする。
# 探す場所の下は 1 回だけ走査し、同じプロセスで探す場所が変わらない限り結果を使い回す。
# テスト用の継ぎ目（利用側が変えるのは BOOCH_CLEANUP_PROJECT_ROOTS だけにする）。
booch_cleanup_docker_project_alive() { # project
  local project=$1 roots=${BOOCH_CLEANUP_PROJECT_ROOTS:-}
  [ -n "$project" ] && [ -n "$roots" ] || return 0
  [ "${_BOOCH_CLEANUP_NAMES_ROOTS-}" = "$roots" ] || _booch_cleanup_collect_project_names "$roots"
  [ -n "${_BOOCH_CLEANUP_PROJECT_NAMES[$project]+x}" ]
}

# roots（`:` 区切りの glob）の直下にあるディレクトリ名を、compose と同じ規則で正規化して
# _BOOCH_CLEANUP_PROJECT_NAMES（連想配列）に集める。
_booch_cleanup_collect_project_names() { # roots
  declare -gA _BOOCH_CLEANUP_PROJECT_NAMES=()
  _BOOCH_CLEANUP_NAMES_ROOTS=$1
  local -a dirs
  local r d n IFS=:
  # shellcheck disable=SC2206  # roots を `:` で分けて、各要素を glob として展開する（意図的に無引用）
  dirs=($1)
  for r in "${dirs[@]}"; do
    # 末尾の / でディレクトリだけに一致させる。一致しなければ "*" が残り、正規化で空になる。
    for d in "$r"/*/; do
      n=${d%/}
      n=${n##*/}
      n=${n,,}
      n=${n//[^a-z0-9_-]/}
      [ -n "$n" ] && _BOOCH_CLEANUP_PROJECT_NAMES[$n]=1
    done
  done
}

# どのコンテナからも参照されていない volume のうち、消しても再作成で戻るものを削除する。
#   匿名 volume（名前が 64 桁の hex か、com.docker.volume.anonymous ラベル付き）: 削除する。
#     compose を -v 無しで down すると残り、次の up では新しい匿名 volume が作られる
#   名前が cache_glob のどれかに一致する volume: 削除する（ビルドキャッシュ等を想定）
#   名前が orphan:<glob> のどれかに一致し、compose のプロジェクトが見当たらない volume: 削除する
#     （node_modules のように、消すと install し直しになる依存を想定。作業中のプロジェクトの
#     ものは残し、消した worktree や使い捨て環境の残骸だけを消す。生死の判定は
#     booch_cleanup_docker_project_alive）
#   それ以外の名前付き volume: DB のデータを含みうるので消さず、名前と大きさを表示するだけ。
#     プロジェクトが見当たらないものには、その旨を添える
# glob は bash のパターン（例: '*[_-]cache' 'orphan:*node-modules'）。何を消してよいかは利用側が
# 決める。消す前に一覧（匿名は短縮 ID / 大きさ / 作成日時）と合計を出して y/N 確認を挟む
# （tty 無し＝非対話なら見送り）。
# `docker volume prune` は Docker 23 未満だと名前付きも消すので使わず、名前を指定して消す。
booch_cleanup_docker_volumes_prune() { # [assume_yes] [cache_glob | orphan:glob]...
  local assume_yes=${1:-false}
  [ $# -gt 0 ] && shift
  local -a cache_globs=() orphan_globs=()
  local spec
  for spec in "$@"; do
    case $spec in
      orphan:*) orphan_globs+=("${spec#orphan:}") ;;
      *) cache_globs+=("$spec") ;;
    esac
  done
  _booch_cleanup_docker_ready || return 0
  # 大きさの集計（system df -v）は数秒かかるので、未使用 volume が無ければ打たずに終える。
  if [ -z "$(docker volume ls -q -f dangling=true 2>/dev/null)" ]; then
    echo "  削除できる未使用 volume はありません"
    return 0
  fi
  # named_size / keep_size の値は "大きさ" か "大きさ|注記"。
  if [ ${#orphan_globs[@]} -gt 0 ] && [ -z "${BOOCH_CLEANUP_PROJECT_ROOTS:-}" ]; then
    echo "  (BOOCH_CLEANUP_PROJECT_ROOTS が未設定なので、orphan: の volume は消さない)"
  fi
  local -A anon_size=() named_size=() keep_size=()
  local name links size labels project gone
  while IFS='|' read -r name links size labels; do
    [ -n "$name" ] && [ "$links" = 0 ] || continue
    if [[ $name =~ ^[0-9a-f]{64}$ || ,$labels, == *,com.docker.volume.anonymous=* ]]; then
      anon_size[$name]=$size
      continue
    fi
    if _booch_cleanup_match_any "$name" "${cache_globs[@]}"; then
      named_size[$name]="$size|キャッシュ"
      continue
    fi
    project=
    [[ ,$labels, =~ ,com\.docker\.compose\.project=([^,]*), ]] && project=${BASH_REMATCH[1]}
    gone=
    booch_cleanup_docker_project_alive "$project" || gone="プロジェクト $project が見当たらない"
    if [ -n "$gone" ] && _booch_cleanup_match_any "$name" "${orphan_globs[@]}"; then
      named_size[$name]="$size|$gone"
    else
      keep_size[$name]="$size${gone:+|$gone}"
    fi
  done < <(booch_cleanup_docker_volume_rows)

  if [ ${#keep_size[@]} -gt 0 ]; then
    echo "  残す未使用 volume（データを含みうる。不要なら個別に 'docker volume rm'）:"
    _booch_cleanup_volume_list keep_size
  fi
  if [ ${#anon_size[@]} -eq 0 ] && [ ${#named_size[@]} -eq 0 ]; then
    echo "  削除できる未使用 volume はありません"
    return 0
  fi
  if [ ${#anon_size[@]} -gt 0 ]; then
    # 停止しただけのコンテナが消されると、その匿名 volume もここに来る。DB のイメージは
    # VOLUME を宣言するので、名前付き volume を当てていない DB の実データは匿名 volume に
    # しか無い。どれを消すのか判断できるよう、新しい順に大きさと作成日時を出す。
    echo "  削除候補の匿名 volume（新しい順）:"
    local created
    while IFS='|' read -r name created; do
      [ -n "$name" ] || continue
      printf '    %-14s %-10s %s\n' "${name:0:12}" "${anon_size[$name]:-?}" "${created:0:10} ${created:11:5}"
    done < <(booch_cleanup_docker_volume_created "${!anon_size[@]}" | sort -t'|' -k2,2r)
  fi
  if [ ${#named_size[@]} -gt 0 ]; then
    echo "  削除候補の名前付き volume:"
    _booch_cleanup_volume_list named_size
  fi
  printf '  回収見込み: 匿名 volume %d 個 %s / 名前付き volume %d 個 %s\n' \
    "${#anon_size[@]}" "$(printf '%s\n' "${anon_size[@]}" | _booch_cleanup_size_sum)" \
    "${#named_size[@]}" "$(printf '%s\n' "${named_size[@]%%|*}" | _booch_cleanup_size_sum)"
  if ! booch_confirm_yes_no "  これらの volume を削除しますか?" "$assume_yes"; then
    echo "  見送りました"
    return 0
  fi
  # 名前を全部並べると表示が埋まるので、コマンドは件数で示す。消した名前の出力は捨て、
  # 失敗（確認の後で使われ始めた volume など）だけを表示する。
  printf '  %s$ docker volume rm <匿名 %d 個 + 名前付き %d 個>%s\n' \
    "$_BOOCH_COLOR_YELLOW" "${#anon_size[@]}" "${#named_size[@]}" "$_BOOCH_COLOR_RESET"
  docker volume rm "${!anon_size[@]}" "${!named_size[@]}" 2>&1 >/dev/null | sed 's/^/    /' || true
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
