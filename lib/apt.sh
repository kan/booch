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

# sources.list.d の場所（テストで temp に差し替えられる）。
: "${BOOCH_APT_SOURCES_DIR:=/etc/apt/sources.list.d}"

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

  local tmp; tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN   # 成否いずれの経路でも temp を片付ける

  # curl を temp に落としてから処理する（パイプにせず失敗を確実に捕捉する）。
  if ! curl -fsSL "$url" -o "$tmp"; then
    echo "apt: 鍵の取得に失敗: $url" >&2
    return 1
  fi
  if ! sudo install -m 0755 -d "$(dirname "$keyring")"; then
    echo "apt: keyring ディレクトリ作成に失敗: $(dirname "$keyring")" >&2
    return 1
  fi
  if [ "$mode" = dearmor ]; then
    if ! sudo gpg --dearmor --yes -o "$keyring" "$tmp"; then
      echo "apt: gpg --dearmor に失敗: $url" >&2
      return 1
    fi
  else
    if ! sudo install -m 0644 "$tmp" "$keyring"; then
      echo "apt: keyring 配置に失敗: $keyring" >&2
      return 1
    fi
  fi
  if ! sudo chmod go+r "$keyring"; then
    echo "apt: chmod に失敗: $keyring" >&2
    return 1
  fi
}

# deb 行を sources.list.d/<name>.list に書き込む。
booch_apt_write_list() { # name deb-line
  printf '%s\n' "$2" | sudo tee "$BOOCH_APT_SOURCES_DIR/$1.list" >/dev/null
}

# 対象 repo のコードネームを解決する。wanted の dists/ が無ければ fallback を使う。
booch_apt_resolve_codename() { # base-url wanted fallback
  local base=$1 wanted=$2 fallback=$3
  if booch_apt_dist_exists "$base" "$wanted"; then
    printf '%s' "$wanted"
  else
    printf 'apt: %s に %s 向けがまだありません。%s にフォールバックします。\n' \
      "$base" "$wanted" "$fallback" >&2
    printf '%s' "$fallback"
  fi
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
