#!/usr/bin/env bash
# GitHub Releases ヘルパー。最新タグ取得とリリース資産のダウンロードを共通化する
# （delta / codex / roji / circleci など、GitHub からバイナリを取るジョブが共用する）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/github.sh"
#   tag=$(booch_github_latest_tag dandavison/delta) || return 1
#   booch_github_download_asset dandavison/delta "$tag" "git-delta-musl_${tag}_amd64.deb" /tmp/d.deb
#
# 依存: curl, jq。
#
# テスト用の継ぎ目（seam）。次を上書きすると network 無しで純粋ロジック
# （JSON 解析・URL 組み立て）を検証できる:
#   booch_github_api <path>        api.github.com/<path> の JSON を stdout へ
#   booch_github_fetch <url> <dest> URL を dest へダウンロード

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
