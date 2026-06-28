#!/usr/bin/env bash
# booch 提供ジョブ: Codex CLI の導入 / 更新（非対話）。
#
# GitHub Releases の musl 静的バイナリ（tar.gz）を /usr/local/bin/codex へ配置する。
# 旧 npm 版（@openai/codex）の撤去は移行残渣なので含めない（利用側の custom に残す）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/arch.sh"
#   source "$BOOCH_ROOT/lib/github.sh"
#   source "$BOOCH_ROOT/jobs/codex.sh"
#   booch_job codex "Codex CLI" job_codex 120
#
# 依存: lib/arch.sh, lib/github.sh, curl, jq, tar, sudo。
#
# テスト用の継ぎ目（seam）:
#   booch_codex_installed_version  現在の版（未導入なら空）
#   booch_codex_latest             最新タグ（rust-vX.Y.Z 形式）
#   booch_codex_arch               資産アーキ（x86_64 / aarch64）
#   booch_codex_install <tag> <arch>  実際の導入（副作用）

booch_codex_installed_version() {
  command -v codex >/dev/null 2>&1 || return 0
  # `codex --version` は "codex-cli 0.142.3" 形式。末尾にハッシュ等が付いても壊れない
  # よう、位置ではなく X.Y.Z パターンで最初の版を取り出す（取れなければ空＝未導入扱い）。
  codex --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

booch_codex_latest() {
  booch_github_latest_tag openai/codex
}

# Codex の配布アーキ名（x86_64 / aarch64）。lib/arch.sh の rust 系ラッパー。
booch_codex_arch() { booch_arch_rust_style; }

# アーカイブ／バイナリの基底名（純粋関数）。資産は "<base>.tar.gz"、展開後の
# バイナリ名は "<base>"。
booch_codex_artifact() { # arch
  printf 'codex-%s-unknown-linux-musl' "$1"
}

booch_codex_install() { # tag arch
  local tag=$1 arch=$2
  local base; base=$(booch_codex_artifact "$arch")
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  booch_github_download_asset openai/codex "$tag" "${base}.tar.gz" "$tmp/${base}.tar.gz" || return 1
  tar -xzf "$tmp/${base}.tar.gz" -C "$tmp" || return 1
  # 現在のリリースは tarball 最上位に <base> 単体のバイナリ（検証済み）。万一レイアウトが
  # 変わったら install の不可解なエラーでなく明示エラーにする。
  if [ ! -f "$tmp/${base}" ]; then
    echo "codex: 展開後にバイナリが見つからない: ${base}" >&2
    return 1
  fi
  sudo install -m 0755 "$tmp/${base}" /usr/local/bin/codex
}

job_codex() {
  local arch current latest norm
  arch=$(booch_codex_arch) || return 1
  current=$(booch_codex_installed_version)
  latest=$(booch_codex_latest) || return 1
  # タグは rust-vX.Y.Z。codex --version は素のバージョンなので、比較・表示用に
  # rust-v / v を外して正規化する。
  norm=${latest#rust-v}
  norm=${norm#v}

  if [ -z "$current" ]; then
    booch_status "installing codex ${norm}..."
    booch_codex_install "$latest" "$arch"
    booch_result "Codex CLI" installed "" "$norm"
  elif [ "$current" != "$norm" ]; then
    booch_status "updating codex ${current} -> ${norm}..."
    booch_codex_install "$latest" "$arch"
    booch_result "Codex CLI" updated "$current" "$norm"
  else
    booch_result "Codex CLI" current "$current"
  fi
}
