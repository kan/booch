#!/usr/bin/env bash
# booch 提供ジョブ: CircleCI CLI の導入 / 更新（非対話）。
#
# GitHub Releases の tar.gz（ネストした circleci バイナリ）を /usr/local/bin/circleci へ
# 配置する。公式 install.sh / 自己更新は配布チャネルが古い版に張り付くため使わず、
# GitHub Releases から直接取得する。x86_64 / aarch64 対応。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/arch.sh"
#   source "$BOOCH_ROOT/lib/github.sh"
#   source "$BOOCH_ROOT/lib/verify.sh"
#   source "$BOOCH_ROOT/jobs/circleci.sh"
#   booch_job circleci "CircleCI CLI" job_circleci 120
#
# 依存: lib/arch.sh, lib/github.sh, lib/verify.sh, curl, jq, tar, sudo, find。
#
# テスト用の継ぎ目（seam）:
#   booch_circleci_installed_version  現在の版（未導入なら空）
#   booch_circleci_latest             最新タグ（vX.Y.Z）
#   booch_circleci_arch               資産アーキ（amd64 / arm64）
#   booch_circleci_install <tag> <arch>  実際の導入（副作用）

booch_circleci_installed_version() {
  command -v circleci >/dev/null 2>&1 || return 0
  # `circleci version` は "0.1.38646+hash (release)" 形式。X.Y.Z を取り出す。
  circleci version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

booch_circleci_latest() {
  booch_github_latest_tag CircleCI-Public/circleci-cli
}

# CircleCI の配布アーキ名（amd64 / arm64）。lib/arch.sh の dpkg 系ラッパー。
booch_circleci_arch() { booch_arch_dpkg_style; }

# 資産/展開ディレクトリの基底名（純粋関数）。資産は "<base>.tar.gz"、展開後の
# バイナリは "<base>/circleci"。ver はタグから v を除いた値。
booch_circleci_asset_base() { # ver arch
  printf 'circleci-cli_%s_linux_%s' "$1" "$2"
}

booch_circleci_install() { # tag arch
  local tag=$1 arch=$2
  local ver=${tag#v}
  local base; base=$(booch_circleci_asset_base "$ver" "$arch")
  local asset="${base}.tar.gz"
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  booch_github_download_asset CircleCI-Public/circleci-cli "$tag" "$asset" "$tmp/cci.tar.gz" || return 1
  # 同リリースの checksums.txt（"<hash>  <filename>" 形式）を引き、tar.gz を展開前に
  # 検証する。期待値が拾えない / 不一致なら sudo install へ進まず止める。
  booch_github_download_asset CircleCI-Public/circleci-cli "$tag" \
    "circleci-cli_${ver}_checksums.txt" "$tmp/checksums.txt" || return 1
  if ! booch_verify_sha256 "$tmp/cci.tar.gz" "$(booch_verify_pick "$asset" < "$tmp/checksums.txt")"; then
    echo "circleci: tar.gz の SHA256 検証に失敗: $asset" >&2
    return 1
  fi
  tar -xzf "$tmp/cci.tar.gz" -C "$tmp" || return 1
  # 既知パス（<base>/circleci）を優先し、レイアウト差異には find でフォールバックする。
  local bin="$tmp/${base}/circleci"
  [ -f "$bin" ] || bin=$(find "$tmp" -name circleci -type f -print -quit)
  if [ -z "$bin" ] || [ ! -f "$bin" ]; then
    echo "circleci: 展開後にバイナリが見つからない" >&2
    return 1
  fi
  sudo install -m 0755 "$bin" /usr/local/bin/circleci
}

job_circleci() {
  local arch current latest ver
  arch=$(booch_circleci_arch) || return 1
  current=$(booch_circleci_installed_version)
  latest=$(booch_circleci_latest) || return 1
  ver=${latest#v}

  if [ -z "$current" ]; then
    booch_status "installing circleci ${ver}..."
    booch_circleci_install "$latest" "$arch"
    booch_result "CircleCI CLI" installed "" "$ver"
  elif [ "$current" != "$ver" ]; then
    booch_status "updating circleci ${current} -> ${ver}..."
    booch_circleci_install "$latest" "$arch"
    booch_result "CircleCI CLI" updated "$current" "$ver"
  else
    booch_result "CircleCI CLI" current "$current"
  fi
}
