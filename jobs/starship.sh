#!/usr/bin/env bash
# booch 提供ジョブ: Starship プロンプトの導入 / 更新（非対話）。
#
# GitHub Releases の musl 静的バイナリ（tar.gz、最上位に starship 単体）を
# /usr/local/bin/starship へ配置する。apt に無いため公式 install.sh / パッケージには
# 頼らず GitHub Releases から直接取得する。同リリースの per-asset ".sha256"（ハッシュ
# 64 桁のみ、ファイル名を含まない）で tar.gz を展開前に検証する。x86_64 / aarch64 対応。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/arch.sh"
#   source "$BOOCH_ROOT/lib/github.sh"
#   source "$BOOCH_ROOT/lib/verify.sh"
#   source "$BOOCH_ROOT/jobs/starship.sh"
#   booch_job starship "Starship" job_starship 180
#
# 依存: lib/arch.sh, lib/github.sh, lib/verify.sh, curl, jq, tar, sudo, find。
#
# テスト用の継ぎ目（seam）:
#   booch_starship_installed_version  現在の版（未導入なら空）
#   booch_starship_latest             最新タグ（vX.Y.Z）
#   booch_starship_arch               資産アーキ（x86_64 / aarch64）
#   booch_starship_install <tag> <arch>  実際の導入（副作用）

booch_starship_installed_version() {
  command -v starship >/dev/null 2>&1 || return 0
  # `starship --version` は "starship 1.26.0" 形式。末尾にハッシュ等が付いても壊れない
  # よう、位置ではなく X.Y.Z パターンで最初の版を取り出す（取れなければ空＝未導入扱い）。
  starship --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

booch_starship_latest() {
  booch_github_latest_tag starship/starship
}

# Starship の配布アーキ名（x86_64 / aarch64）。lib/arch.sh の rust 系ラッパー。
booch_starship_arch() { booch_arch_rust_style; }

# アーカイブの基底名（純粋関数）。資産は "<base>.tar.gz"、展開後は最上位に "starship"。
booch_starship_artifact() { # arch
  printf 'starship-%s-unknown-linux-musl' "$1"
}

booch_starship_install() { # tag arch
  local tag=$1 arch=$2
  local base; base=$(booch_starship_artifact "$arch")
  local asset="${base}.tar.gz"
  local tmp; tmp=$(mktemp -d)
  # 発火時に自身を解除し、RETURN トラップが呼び出し元へ漏れて再発火するのを防ぐ
  # （呼び出し元の set -u 下で解放済みローカル変数を踏んで落ちないように）。
  trap 'rm -rf "${tmp:-}"; trap - RETURN' RETURN
  booch_github_download_asset starship/starship "$tag" "$asset" "$tmp/st.tar.gz" || return 1
  # 同リリースの per-asset .sha256（ハッシュ 64 桁のみ）を引き、tar.gz を展開前に検証する。
  # checksums.txt 形式（circleci）と違いファイル名を含まないため、booch_verify_pick では
  # なく先頭フィールドをそのまま期待値にする。拾えない / 不一致なら sudo install へ進まない。
  booch_github_download_asset starship/starship "$tag" "${asset}.sha256" "$tmp/st.sha256" || return 1
  if ! booch_verify_sha256 "$tmp/st.tar.gz" "$(awk '{print $1; exit}' "$tmp/st.sha256")"; then
    echo "starship: tar.gz の SHA256 検証に失敗: $asset" >&2
    return 1
  fi
  tar -xzf "$tmp/st.tar.gz" -C "$tmp" || return 1
  # 現在のリリースは tarball 最上位に starship 単体。既知パスを優先し、レイアウト差異
  # （サブディレクトリ化）には find でフォールバックする（codex / circleci と同方針）。
  local bin="$tmp/starship"
  [ -f "$bin" ] || bin=$(find "$tmp" -maxdepth 2 -type f -name starship -print -quit)
  if [ -z "$bin" ] || [ ! -f "$bin" ]; then
    echo "starship: 展開後にバイナリが見つからない" >&2
    return 1
  fi
  sudo install -m 0755 "$bin" /usr/local/bin/starship
}

job_starship() {
  local arch current latest
  arch=$(booch_starship_arch) || return 1
  current=$(booch_starship_installed_version)
  latest=$(booch_starship_latest) || return 1
  # タグは vX.Y.Z。starship --version は素の版なので、比較・表示用に v を外す。
  # 比較・表示は v を外した値、install には raw タグ "$latest" を渡す。
  booch_job_sync "Starship" "starship" "$current" "${latest#v}" booch_starship_install "$latest" "$arch"
}
