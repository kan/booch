#!/usr/bin/env bash
# GitHub Releases ヘルパー。最新タグ取得とリリース資産のダウンロードを共通化する
# （delta / codex / circleci など、GitHub からバイナリを取るジョブが共用する）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/github.sh"
#   tag=$(booch_github_latest_tag dandavison/delta) || return 1
#   booch_github_download_asset dandavison/delta "$tag" "git-delta-musl_${tag}_amd64.deb" /tmp/d.deb
#   booch_github_verify_asset dandavison/delta "$tag" "git-delta-musl_${tag}_amd64.deb" /tmp/d.deb || return 1
#
# booch_github_verify_asset は、Releases API が各資産に付ける digest（GitHub がアップロード時に
# 計算した SHA256）で照合する。upstream がチェックサムを公開していないツールでも、転送中の破損や
# 改ざんは検出できる（資産そのものの差し替え＝上流のアカウント侵害は検出できない）。digest が
# 付いていない（古いリリース）ときは警告して照合を飛ばす。API の取得に失敗したときと、digest が
# 一致しないときは失敗にする。
#
# 依存: curl, jq, lib/verify.sh（未読み込みならここで同じディレクトリから読む）。
#
# テスト用の継ぎ目（seam）。次を上書きすると network 無しで純粋ロジック
# （JSON 解析・URL 組み立て）を検証できる:
#   booch_github_api <path>        api.github.com/<path> の JSON を stdout へ
#   booch_github_fetch <url> <dest> URL を dest へダウンロード

# 照合は lib/verify.sh の booch_verify_sha256 に任せる。github.sh だけを読む既存の利用側
# （CI の shellcheck 導入など）を壊さないよう、未定義なら自分で読み込む。BOOCH_ROOT を優先し、
# 無ければこのファイルの隣を見る。どちらにも無い（`source <(...)` で読んだ等）ときも source 自体は
# 失敗させない ―― 照合の時点で booch_verify_sha256 が無くて失敗するので、未検証では進まない。
if ! declare -F booch_verify_sha256 >/dev/null 2>&1; then
  for _booch_github_verify in "${BOOCH_ROOT:-}/lib/verify.sh" \
    "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/verify.sh"; do
    if [ -f "$_booch_github_verify" ]; then
      # shellcheck source=lib/verify.sh
      source "$_booch_github_verify"
      break
    fi
  done
  unset _booch_github_verify
fi

booch_github_api() { # path
  curl -fsSL --max-time 15 "https://api.github.com/$1"
}

booch_github_fetch() { # url dest
  curl -fsSL "$1" -o "$2"
}

# 最新リリースのタグを返す（例: v1.2.3 / rust-v0.20.0）。取得不能・null なら非 0。
booch_github_latest_tag() { # owner/repo
  local repo=$1 tag
  # 非 JSON（レート制限 HTML 等）で jq が非 0 終了しても、空チェックだけを唯一の
  # 判定にする（`|| tag=""`）。これが無いと set -e の caller が bare で呼んだとき、
  # 代入が -z チェック前に中断し診断を出さず誤った rc を返す（runner はジョブを
  # `bash -c "set -e"` で走らせるため現実的）。
  tag=$(booch_github_api "repos/$repo/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null) || tag=""
  if [ -z "$tag" ]; then
    echo "github: 最新タグの取得に失敗: $repo" >&2
    return 1
  fi
  printf '%s' "$tag"
}

# 指定タグのリリース資産を dest へダウンロードする。
# 引数は信頼前提（URL エンコードしない）。asset/tag に空白や / が入ると URL が壊れる。
booch_github_download_asset() { # owner/repo tag asset dest
  local repo=$1 tag=$2 asset=$3 dest=$4
  booch_github_fetch "https://github.com/$repo/releases/download/$tag/$asset" "$dest"
}

# 指定タグの資産の SHA256（Releases API の digest から "sha256:" を外した hex）を返す。API の
# 取得に失敗した / 応答が JSON でないときは非 0。digest が無い（古いリリース / sha256 以外の
# 形式）ときは空で 0。jq の失敗はパイプに通さず明示的に見る（caller の pipefail で判定が揺れない）。
booch_github_asset_digest() { # owner/repo tag asset
  local json digest
  json=$(booch_github_api "repos/$1/releases/tags/$2") || return 1
  [ -n "$json" ] || return 1
  digest=$(jq -r --arg name "$3" \
    'first(.assets[]? | select(.name == $name) | .digest // empty) // empty' <<<"$json" 2>/dev/null) \
    || return 1
  case "$digest" in
    sha256:*) printf '%s\n' "${digest#sha256:}" ;;
  esac
}

# ダウンロード済みの資産 file を digest で照合する（冒頭コメント参照）。digest が付いていない
# ときだけ警告して照合を飛ばす。API の取得に失敗したとき（レート制限など）は、未検証の資産を
# 導入へ進めないよう失敗にする。
booch_github_verify_asset() { # owner/repo tag asset file
  local want
  if ! want=$(booch_github_asset_digest "$1" "$2" "$3"); then
    echo "github: $3 の digest を取得できません（API の失敗）。SHA256 を照合できないため中断します" >&2
    return 1
  fi
  if [ -z "$want" ]; then
    echo "github: $3 に digest が無いため、SHA256 を照合せずに続けます" >&2
    return 0
  fi
  booch_verify_sha256 "$4" "$want"
}
