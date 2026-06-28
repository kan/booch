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
  # 完了マーカは <name>.list のみ。これがあれば導入済みとみなしスキップする
  # （鍵だけ消えた半端な状態は補修しないが、運用上は十分）。
  [ -f "$BOOCH_APT_SOURCES_DIR/$name.list" ] && return 0
  booch_apt_install_key "$key_url" "$keyring" "$mode" || return 1
  booch_apt_write_list "$name" "$deb_line"
}
