#!/usr/bin/env bash
# booch 提供ジョブ: delta (git pager) の導入 / 更新（非対話）。
#
# GitHub Releases の musl 静的版 .deb を使う。動的版 git-delta は新しい libc を要求し、
# 古い Ubuntu では configure に失敗するため、OS 非依存な musl 版で統一する。
# 旧 diff-highlight 等の移行残渣の掃除はここに含めない（利用側の custom job に残す）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/github.sh"
#   source "$BOOCH_ROOT/jobs/delta.sh"
#   booch_job delta "delta (git pager)" job_delta 120
#
# 依存: lib/github.sh, curl, jq, dpkg, sudo。
#
# テスト用の継ぎ目（seam）:
#   booch_delta_installed_version  現在の版（未導入なら空）
#   booch_delta_latest             最新タグ（GitHub Releases）
#   booch_delta_arch               .deb のアーキテクチャ（amd64 / arm64）
#   booch_delta_install <tag> <arch>  実際の導入（副作用）

booch_delta_installed_version() {
  command -v delta >/dev/null 2>&1 || return 0
  # 1 行目の第 2 フィールドだけを取る（複数行出力でも版比較が壊れないよう exit で止める）。
  delta --version 2>/dev/null | awk '{print $2; exit}'
}

booch_delta_latest() {
  booch_github_latest_tag dandavison/delta
}

booch_delta_arch() {
  local a; a=$(dpkg --print-architecture)
  case "$a" in
    amd64 | arm64) printf '%s' "$a" ;;
    *) echo "delta: 未対応アーキテクチャ: $a" >&2; return 1 ;;
  esac
}

# 資産名（純粋関数。テスト容易性のため分離）。
booch_delta_asset() { # tag arch
  printf 'git-delta-musl_%s_%s.deb' "$1" "$2"
}

booch_delta_install() { # tag arch
  local tag=$1 arch=$2
  local tmp; tmp=$(mktemp -d)
  # 発火時に自身を解除し、RETURN トラップが呼び出し元へ漏れて再発火するのを防ぐ
  # （呼び出し元の set -u 下で解放済みローカル変数を踏んで落ちないように）。
  trap 'rm -rf "${tmp:-}"; trap - RETURN' RETURN
  # 先に DL してから入れ替える（network 失敗ならパージ前に抜ける）。go.sh のような
  # ステージ＋原子的入替ではなく purge→install だが、musl .deb は依存なしで dpkg も
  # ほぼトランザクショナルなため、パージ後に install 失敗する残存ウィンドウは小さい。
  booch_github_download_asset dandavison/delta "$tag" \
    "$(booch_delta_asset "$tag" "$arch")" "$tmp/delta.deb" || return 1
  # 動的版 git-delta が入っていると /usr/bin/delta を奪い合い dpkg が衝突するため、
  # 先にパージしてから musl 版を入れる。
  if dpkg -s git-delta >/dev/null 2>&1; then
    sudo dpkg -P git-delta || return 1
  fi
  sudo dpkg -i "$tmp/delta.deb"
}

job_delta() {
  local arch current latest
  arch=$(booch_delta_arch) || return 1
  current=$(booch_delta_installed_version)
  latest=$(booch_delta_latest) || return 1

  # delta は bare タグ（例: 0.18.2）で、資産名も bare 前提。万一 v 付きタグになっても
  # 永久更新ループに陥らないよう、比較は v を外して行う（資産名は raw タグのままなので、
  # v 付きへ移行した場合は DL が 404 で明示失敗し、その時点で対応する）。install には raw
  # タグ "$latest" を渡す。
  booch_job_sync "delta" "delta" "${current#v}" "${latest#v}" booch_delta_install "$latest" "$arch"
}
