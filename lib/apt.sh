#!/usr/bin/env bash
# APT サードパーティリポジトリ追加のヘルパー。
#
# dotfiles 等が Docker / gh / acli / ngrok / NodeSource などを個別にベタ書きしていた
# 「鍵取得 → keyring 配置 → sources.list.d へ deb 行」を共通化する。新しい Ubuntu
# リリース直後に対象 repo へ当該コードネームの dists/ がまだ無い場合のフォールバック
# 解決もここに置く（lib/os.sh の BOOCH_OS_CODENAME を呼び出し側が渡す想定）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/apt.sh"
#   codename=$(booch_apt_resolve_codename \
#     "https://download.docker.com/linux/ubuntu" "$BOOCH_OS_CODENAME" "noble")
#   booch_apt_add_repo docker \
#     "https://download.docker.com/linux/ubuntu/gpg" \
#     "/etc/apt/keyrings/docker.asc" raw \
#     "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable"
#
# 依存: curl, gpg, sudo, dpkg（呼び出し側）, install, tee。
#
# テスト用の継ぎ目（seam）。次を上書きすると sudo / network 無しで純粋ロジック
# （フォールバック判定・冪等スキップ）を検証できる:
#   booch_apt_dist_exists <base-url> <codename>   dists/<codename>/Release の存在
#   booch_apt_install_key <url> <keyring> <mode>  鍵取得と keyring 配置（mode: dearmor|raw）
#   booch_apt_write_list  <name> <deb-line>       sources.list.d/<name>.list 生成
#   booch_apt_keyring_records <keyring>           keyring の鍵レコード（gpg コロン形式）

# sources.list.d の場所（テストで temp に差し替えられる）。
: "${BOOCH_APT_SOURCES_DIR:=/etc/apt/sources.list.d}"

# 署名鍵を期限切れの何日前から取り直すか。0 にすると「切れてから」になる。上流は
# 期限前に新鍵を足した keyring へ差し替えるのが通例なので、既定は前倒しにしてある。
: "${BOOCH_APT_KEY_RENEW_DAYS:=30}"

# 対象 repo に当該コードネームの dists/<codename>/Release があるか（HEAD で確認）。
booch_apt_dist_exists() { # base-url codename
  curl -fsI --max-time 10 "${1}/dists/${2}/Release" >/dev/null 2>&1
}

# 鍵を取得して keyring に配置する。mode=dearmor なら gpg --dearmor、raw ならそのまま。
# add_repo からは `... || return 1` で呼ばれるため、その文脈では本体の errexit が
# 無効になる。各 sudo ステップの失敗を明示的に判定し、1 つでも失敗したら非 0 を返す
# （成功扱いで write_list へ進み、鍵の無い壊れた .list を残さないため）。
booch_apt_install_key() { # url keyring mode
  local url=$1 keyring=$2 mode=$3
  case "$mode" in
    dearmor | raw) ;;
    *) echo "apt: 未知の key mode: $mode（dearmor|raw）" >&2; return 2 ;;
  esac

  local tmp armored bin; tmp=$(mktemp); armored=
  # 成否いずれの経路でも temp を片付ける。発火時に自身を解除し（`trap - RETURN`）、
  # RETURN トラップが呼び出し元の return まで漏れて再発火するのを防ぐ（呼び出し元が
  # `set -u` だと、解放済みローカル変数を踏んで「未割り当て変数」で落ちるため）。
  trap 'rm -f "${tmp:-}" "${armored:-}"; trap - RETURN' RETURN

  # curl を temp に落としてから処理する（パイプにせず失敗を確実に捕捉する）。期限切れの
  # 取り直しで毎回の setup がここを通るので、応答しない網でぶら下がらないよう時間を切る。
  if ! curl -fsSL --max-time 30 "$url" -o "$tmp"; then
    echo "apt: 鍵の取得に失敗: $url" >&2
    return 1
  fi
  # dearmor も sudo の前にローカルで済ませ、配置する中身をここで確定させる。鍵の
  # 取り直し（期限切れ時）が上流未更新で空振りしても keyring を書き換えずに済む。
  if [ "$mode" = dearmor ]; then
    armored=$(mktemp)
    if ! gpg --dearmor --yes -o "$armored" "$tmp"; then
      echo "apt: gpg --dearmor に失敗: $url" >&2
      return 1
    fi
    bin=$armored
  else
    bin=$tmp
  fi
  # 中身が既存と同じなら書かない（無駄な sudo と mtime の更新を避ける）。
  if [ -r "$keyring" ] && cmp -s "$bin" "$keyring"; then
    return 0
  fi
  if ! sudo install -m 0755 -d "$(dirname "$keyring")"; then
    echo "apt: keyring ディレクトリ作成に失敗: $(dirname "$keyring")" >&2
    return 1
  fi
  # apt は keyring を root 以外からも読むので 0644 で置く（install -m がそのまま満たす）。
  if ! sudo install -m 0644 "$bin" "$keyring"; then
    echo "apt: keyring 配置に失敗: $keyring" >&2
    return 1
  fi
}

# deb 行を sources.list.d/<name>.list に書き込む。
booch_apt_write_list() { # name deb-line
  printf '%s\n' "$2" | sudo tee "$BOOCH_APT_SOURCES_DIR/$1.list" >/dev/null
}

# 対象 repo のコードネームを解決する。wanted の dists/ が無ければ fallback を使う。
#
# name を渡すと、既に <name>.list があるときはそこに記録されたコードネームをそのまま返し、
# HEAD チェックを省く。booch_apt_add_repo は鍵の期限切れを見るために毎回呼ぶ必要があり、
# 呼び出しを .list の有無で囲えないため、通信を省く判断はここが持つ（オフライン時に
# 誤って fallback へ落ちるのも防ぐ）。
booch_apt_resolve_codename() { # base-url wanted fallback [name]
  local base=$1 wanted=$2 fallback=$3 name=${4:-} recorded
  if [ -n "$name" ] && [ -f "$BOOCH_APT_SOURCES_DIR/$name.list" ]; then
    # 自身が書いた行なので書式は "deb [opts] <base-url> <codename> <component>" に固定。
    recorded=$(awk '$1 == "deb" { print $(NF - 1); exit }' "$BOOCH_APT_SOURCES_DIR/$name.list")
    if [ -n "$recorded" ]; then
      printf '%s' "$recorded"
      return 0
    fi
  fi
  if booch_apt_dist_exists "$base" "$wanted"; then
    printf '%s' "$wanted"
  else
    printf 'apt: %s に %s 向けがまだありません。%s にフォールバックします。\n' \
      "$base" "$wanted" "$fallback" >&2
    printf '%s' "$fallback"
  fi
}

# keyring の鍵レコードを gpg のコロン形式で返す（seam）。gpg が無い / 読めないときは
# 空を返し、呼び出し側は「判定不能」として扱う。
booch_apt_keyring_records() { # keyring
  command -v gpg >/dev/null 2>&1 || return 0
  gpg --show-keys --with-colons "$1" 2>/dev/null
}

# keyring の署名鍵が「いつまで使えるか」を 1 語で返す。値は次のいずれか:
#   unknown  署名鍵を 1 本も読み取れない（gpg が無い / keyring が読めない）＝判定不能
#   expired  署名鍵はあるが、生きているものが 1 本も無い
#   forever  期限の無い署名鍵が生きている
#   <epoch>  生きている署名鍵の期限のうち最も遅いもの（＝検証が壊れる時刻）
# pub / sub のうち署名能力（capabilities に小文字 s）を持つレコードだけを見る。
# 署名副鍵を持つ keyring では副鍵だけを見る ―― Release へ署名するのは副鍵なので、
# 長寿命の主鍵に隠れて副鍵の期限切れを見落とさないようにするため。
booch_apt_keyring_expiry() { # keyring
  local out
  out=$(booch_apt_keyring_records "$1" | awk -F: '
    $1 != "pub" && $1 != "sub" { next }
    $12 !~ /s/ { next }
    { kind[++n] = $1; validity[n] = $2; expiry[n] = $7; if ($1 == "sub") hassub = 1 }
    END {
      for (i = 1; i <= n; i++) {
        if (hassub && kind[i] != "sub") continue
        seen = 1
        if (validity[i] == "e" || validity[i] == "r" || validity[i] == "i") continue
        alive = 1
        if (expiry[i] == "") { forever = 1; continue }
        if (expiry[i] + 0 > latest) latest = expiry[i] + 0
      }
      if (!seen)    { print "unknown"; exit }
      if (!alive)   { print "expired"; exit }
      if (forever)  { print "forever"; exit }
      print latest
    }
  ')
  # awk 自体が動かない環境で空が漏れないよう、返り値をここで 4 値に正規化する
  # （呼び出し側それぞれに空のガードを持たせない）。
  printf '%s\n' "${out:-unknown}"
}

# 「これより先に期限が来る鍵は取り直す」境界を epoch で返す（猶予日数の唯一の実装）。
booch_apt_key_deadline() { # [grace-days]
  local now
  printf -v now '%(%s)T' -1
  printf '%s' "$(( now + ${1:-$BOOCH_APT_KEY_RENEW_DAYS} * 86400 ))"
}

# keyring に「猶予日数を過ぎてもまだ使える署名鍵」が残っているか（残っていれば 0）。
# 判定不能（unknown）は 0 を返す ―― gpg が無い環境やテストのダミー keyring で、
# 「読めない」を再取得へ倒さないため（不明なら現状維持が安全側）。
booch_apt_keyring_usable() { # keyring [grace-days]
  local expiry; expiry=$(booch_apt_keyring_expiry "$1")
  case "$expiry" in
    unknown | forever) return 0 ;;
    expired) return 1 ;;
    *) [ "$expiry" -gt "$(booch_apt_key_deadline "${2:-}")" ] ;;
  esac
}

# サードパーティ repo を追加する（冪等: 既に <name>.list があれば何もしない）。
# deb 行は呼び出し側が組み立てて渡す（arch / signed-by / codename の差異を吸収する）。
booch_apt_add_repo() { # name key-url keyring mode deb-line
  local name=$1 key_url=$2 keyring=$3 mode=$4 deb_line=$5
  # name はファイル名になるため、ディレクトリ脱出を防ぐ（呼び出し側は信頼するが安全側）。
  case "$name" in
    "" | */* | .*) echo "apt: 不正な repo 名: $name" >&2; return 2 ;;
  esac
  # 完了マーカは <name>.list だが、鍵だけ消えた半端な状態を自己修復するため keyring の
  # 可読性も確認する。両方そろっていれば導入済みとみなしスキップ、欠けていれば入れ直す。
  if [ -f "$BOOCH_APT_SOURCES_DIR/$name.list" ] && [ -r "$keyring" ]; then
    booch_apt_keyring_usable "$keyring" && return 0
    # 鍵の期限切れは .list の有無では分からないので、ここでだけ取り直す（上流は期限前に
    # 新鍵を足した keyring へ差し替えるのが通例）。取り直せなくても repo 自体は既にある
    # ので、警告して続行する ―― repo 追加が本来の役目で、検証の可否は apt update が示す。
    printf '%s[WARN]%s %s の署名鍵が期限切れ（または期限間近）です。鍵を取り直します。\n' \
      "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET" "$name" >&2
    if ! booch_apt_install_key "$key_url" "$keyring" "$mode"; then
      printf '%s[WARN]%s %s の鍵を取り直せませんでした: %s\n' \
        "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET" "$name" "$key_url" >&2
    elif ! booch_apt_keyring_usable "$keyring"; then
      printf '%s[WARN]%s %s は上流の keyring もまだ新鍵を含みません: %s\n' \
        "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET" "$name" "$key_url" >&2
    fi
    return 0
  fi
  booch_apt_install_key "$key_url" "$keyring" "$mode" || return 1
  booch_apt_write_list "$name" "$deb_line"
}

# パッケージが dpkg で導入済みか（seam）。command -v ではなくパッケージ単位で見るので、
# コマンド名 != パッケージ名（gnupg→gpg 等）でも判定がぶれない。
booch_apt_pkg_installed() { # pkg
  dpkg -s "$1" >/dev/null 2>&1
}

# 不足分をまとめて導入する（seam。update してから install する）。
booch_apt_install() { # pkg...
  sudo apt-get update && sudo apt-get install -y "$@"
}

# 指定パッケージのうち未導入のものだけを導入する。全て導入済みなら apt を呼ばない
# （再実行時の無駄な update を避ける）。ブートストラップ前提（curl / gnupg /
# software-properties-common / ca-certificates 等）の確保に使う。
booch_apt_ensure() { # pkg...
  local missing=() p
  for p in "$@"; do
    booch_apt_pkg_installed "$p" || missing+=("$p")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  booch_apt_install "${missing[@]}"
}

# autoremove 可能なパッケージ数（seam）。dry-run なので root 不要。
booch_apt_autoremove_count() {
  apt-get -s autoremove 2>/dev/null | awk '/^Remv/{c++} END{print c+0}'
}

# 不要パッケージがあれば件数と手動コマンドを stderr に通知する（自動削除はしない）。
# 候補があれば 1 を返すので、呼び出し側で警告フラグを立てられる。
# 注意: 候補ありで 1 を返すため、set -e の caller が bare で呼ぶと中断する。
# 通知後も処理を続けたいなら `booch_apt_warn_autoremove || warn=1` のように受ける。
booch_apt_warn_autoremove() {
  local count
  count=$(booch_apt_autoremove_count)
  # 数値以外 / 空（awk 不在等の退化ケース）は 0 とみなす（-eq の構文エラー回避）。
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  [ "$count" -eq 0 ] && return 0
  printf 'apt: autoremove 可能なパッケージが %d 件あります\n' "$count" >&2
  printf '  確認: apt-get -s autoremove\n' >&2
  printf '  実行: sudo apt autoremove\n' >&2
  return 1
}

# preferences.d の場所（テストで temp に差し替えられる）。
: "${BOOCH_APT_PREFERENCES_DIR:=/etc/apt/preferences.d}"
# 色（color.sh 未 source でも set -u を巻き込まないよう空で用意する。add_ppa の警告で使う）。
: "${_BOOCH_COLOR_YELLOW:=}" "${_BOOCH_COLOR_RESET:=}"

# apt を更新し必須パッケージを導入する。update / install の失敗は致命的（非 0 を返す）、
# upgrade は best-effort（一部失敗しても続行）。最後に autoremove 警告を出す（戻り値には
# 影響しない）。どのパッケージを入れるかは利用側が決める。
# 注意: update/install 失敗で非 0 を返すので、caller は `booch_apt_sync ... || halt` で受ける。
booch_apt_upgrade() { sudo apt-get upgrade -y; }   # seam
booch_apt_sync() { # pkg...
  sudo apt-get update || return 1
  booch_apt_upgrade || echo "  [WARN] apt upgrade に一部失敗しました（続行します）" >&2
  sudo apt-get install -y "$@" || return 1
  booch_apt_warn_autoremove || true
}

# add-apt-repository 系の PPA を追加する（鍵 + deb の keyring パターンの booch_apt_add_repo
# とは別系統）。grep_pattern（既定: "ppa:" を除いた owner/repo）が sources.list.d に既にあれば
# スキップ。allow_fail を真にすると追加失敗を警告だけして続行する（新リリース直後に当該
# コードネーム向けが未公開なケース）。どの PPA を使うか・失敗許容かは利用側が決める。
booch_apt_add_ppa() { # ppa [grep_pattern] [allow_fail]
  local ppa=$1 pat=${2:-${1#ppa:}} allow_fail=${3:-}
  # -F: パターンは固定文字列（owner/repo 等）として扱う（メタ文字を含む PPA 名で誤判定しない）。
  grep -rqF "$pat" "$BOOCH_APT_SOURCES_DIR/" 2>/dev/null && return 0
  echo "Adding PPA: $ppa"
  if ! sudo add-apt-repository -y "$ppa"; then
    case "$allow_fail" in
      true | yes | 1)
        printf '%s[WARN]%s PPA %s を追加できませんでした（続行します）\n' \
          "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET" "$ppa" >&2
        return 0 ;;
      *) return 1 ;;
    esac
  fi
}

# preferences.d/<name> に origin pin を書く（ディストリ版が指定 origin の版を上書きしない
# ようにする）。既にあれば何もしない。pin 対象の package / origin / priority は利用側が決める。
booch_apt_pin_origin() { # name package origin priority
  local name=$1 package=$2 origin=$3 priority=$4
  [ -f "$BOOCH_APT_PREFERENCES_DIR/$name" ] && return 0
  printf 'Package: %s\nPin: origin %s\nPin-Priority: %s\n' "$package" "$origin" "$priority" \
    | sudo tee "$BOOCH_APT_PREFERENCES_DIR/$name" > /dev/null
}
