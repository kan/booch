#!/usr/bin/env bash
# booch 提供ジョブ: ShellCheck の導入 / 更新（非対話）。
#
# GitHub Releases の静的バイナリ（tar.xz にネストした shellcheck）を /usr/local/bin/shellcheck へ
# 配置する。Ubuntu の apt 版は各リリースの版に張り付き（例: 24.04 は 0.9.0 固定で SC2329 等の
# 新しい検査が入らない）、CI が使う新しめの shellcheck とローカルがずれるため、GitHub Releases から
# 直接最新を取得して版を揃える。x86_64 / aarch64 対応。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/arch.sh"
#   source "$BOOCH_ROOT/lib/github.sh"
#   source "$BOOCH_ROOT/jobs/shellcheck.sh"
#   booch_job shellcheck "ShellCheck" job_shellcheck 120
#
# 依存: lib/arch.sh, lib/github.sh, curl, jq, tar (xz), sudo, find。
#
# 取得物の検証: upstream (koalaman/shellcheck) はリリースにチェックサムを公開していないため
# 未検証（delta / codex 単体バイナリと同じ扱い。HTTPS + 公式配布元に依存）。upstream が
# checksums を出すようになれば lib/verify.sh で照合を足す。
#
# テスト用の継ぎ目（seam）:
#   booch_shellcheck_installed_version  現在の版（未導入なら空）
#   booch_shellcheck_latest             最新タグ（vX.Y.Z）
#   booch_shellcheck_arch               資産アーキ（x86_64 / aarch64）
#   booch_shellcheck_install <tag> <arch>  実際の導入（副作用）

booch_shellcheck_installed_version() {
  command -v shellcheck >/dev/null 2>&1 || return 0
  # `shellcheck --version` は複数行。"version: 0.11.0" の行から版だけを取る。
  shellcheck --version 2>/dev/null | awk '/^version:/{print $2; exit}'
}

booch_shellcheck_latest() {
  booch_github_latest_tag koalaman/shellcheck
}

# ShellCheck の配布アーキ名（x86_64 / aarch64）。lib/arch.sh の rust 系ラッパー（uname -m 系）。
booch_shellcheck_arch() { booch_arch_rust_style; }

# 資産名（純粋関数）。資産は "shellcheck-<tag>.linux.<arch>.tar.xz"、展開後は
# "shellcheck-<tag>/shellcheck"。
booch_shellcheck_asset() { # tag arch
  printf 'shellcheck-%s.linux.%s.tar.xz' "$1" "$2"
}

booch_shellcheck_install() { # tag arch
  local tag=$1 arch=$2
  local asset; asset=$(booch_shellcheck_asset "$tag" "$arch")
  local tmp; tmp=$(mktemp -d)
  # 発火時に自身を解除し、RETURN トラップが呼び出し元へ漏れて再発火するのを防ぐ
  # （呼び出し元の set -u 下で解放済みローカル変数を踏んで落ちないように）。
  trap 'rm -rf "${tmp:-}"; trap - RETURN' RETURN
  booch_github_download_asset koalaman/shellcheck "$tag" "$asset" "$tmp/sc.tar.xz" || return 1
  tar -xJf "$tmp/sc.tar.xz" -C "$tmp" || return 1
  # 既知パス（shellcheck-<tag>/shellcheck）を優先し、レイアウト差異には find でフォールバック
  # する（circleci / starship と同方針）。
  local bin="$tmp/shellcheck-$tag/shellcheck"
  [ -f "$bin" ] || bin=$(find "$tmp" -maxdepth 2 -type f -name shellcheck -print -quit)
  if [ -z "$bin" ] || [ ! -f "$bin" ]; then
    echo "shellcheck: 展開後にバイナリが見つからない" >&2
    return 1
  fi
  sudo install -m 0755 "$bin" /usr/local/bin/shellcheck
}

job_shellcheck() {
  local arch current latest
  arch=$(booch_shellcheck_arch) || return 1
  current=$(booch_shellcheck_installed_version)
  latest=$(booch_shellcheck_latest) || return 1
  # タグは vX.Y.Z。shellcheck --version は素の版なので、比較・表示用に v を外す。
  # 比較・表示は v を外した値、install には raw タグ "$latest" を渡す（資産名も v 付き前提）。
  booch_job_sync "ShellCheck" "shellcheck" "$current" "${latest#v}" booch_shellcheck_install "$latest" "$arch"
}
