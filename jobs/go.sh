#!/usr/bin/env bash
# booch 提供ジョブ: Go ツールチェインの導入 / 更新（非対話）。
#
# 既定で「未導入なら導入、導入済みでも最新と異なれば更新」する。更新可否を人に
# 確認したい場合は、呼び出し側がこのジョブを登録する前に判断する（並列ランナー
# 内では対話できないため、booch のジョブは非対話に保つ）。
#
# 使い方:
#   source "$BOOCH_ROOT/jobs/go.sh"
#   booch_job go "Go" job_go 300      # tarball 取得を含むため timeout は長めに
#
# 依存: curl, tar, sudo（/usr/local/go へ展開する）, uname。
#
# テスト用の継ぎ目（seam）。次の関数を上書きすると、ネットワーク / sudo 無しで
# job_go の分岐（installed / updated / current / 失敗）を検証できる:
#   booch_go_latest_version       最新版文字列を返す（例: go1.22.0）
#   booch_go_installed_version    現在の版を返す（未導入なら空）
#   booch_go_install <version>    実際の導入（副作用）

# 最新の安定版（go.dev が "go1.X.Y" 形式で返す）。
booch_go_latest_version() {
  curl -fsSL --max-time 10 "https://go.dev/VERSION?m=text" | head -1
}

# 導入済みの版（未導入なら空文字）。
booch_go_installed_version() {
  command -v go >/dev/null 2>&1 || return 0
  go version | awk '{print $3}'
}

# 実行アーキテクチャに対応する Go の配布アーキ名（amd64 / arm64）を返す。
booch_go_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) echo "go: 未対応アーキテクチャ: $(uname -m)" >&2; return 1 ;;
  esac
}

# 指定版を /usr/local/go へ導入する。取得・展開が失敗しても既存の install を
# 壊さないよう、ステージディレクトリへ展開してから rename で入れ替える（同一
# ファイルシステム上の mv はほぼ瞬時で原子的。古い install は入れ替え後に消す）。
booch_go_install() { # <version>
  local version=$1 goarch
  goarch=$(booch_go_arch) || return 1
  local tarball="${version}.linux-${goarch}.tar.gz"
  local tmp; tmp=$(mktemp -d)
  local stage="/usr/local/go.new.$$" old="/usr/local/go.old.$$"
  # tmp と未完成ステージは必ず片付ける。古い install（$old）は残す（万一 swap が
  # 途中で失敗しても直前の install を手で復旧できるようにするため）。
  trap 'rm -rf "$tmp"; sudo rm -rf "$stage"' RETURN

  if ! curl -fsSL "https://go.dev/dl/${tarball}" -o "$tmp/$tarball"; then
    echo "go: tarball の取得に失敗: $tarball" >&2
    return 1
  fi
  sudo rm -rf "$stage"
  sudo mkdir -p "$stage"
  # tarball の最上位は go/。--strip-components=1 で中身を直接ステージへ展開する。
  if ! sudo tar -C "$stage" --strip-components=1 -xzf "$tmp/$tarball"; then
    echo "go: 展開に失敗: $tarball" >&2
    return 1
  fi
  [ -d /usr/local/go ] && sudo mv /usr/local/go "$old"
  sudo mv "$stage" /usr/local/go
  sudo rm -rf "$old"
}

job_go() {
  local current latest
  current=$(booch_go_installed_version)
  latest=$(booch_go_latest_version)
  if [ -z "$latest" ]; then
    echo "go: 最新版の取得に失敗しました" >&2
    return 1
  fi

  if [ -z "$current" ]; then
    booch_status "installing ${latest}..."
    booch_go_install "$latest"
    booch_result "Go" installed "" "$latest"
  elif [ "$current" != "$latest" ]; then
    booch_status "updating ${current} -> ${latest}..."
    booch_go_install "$latest"
    booch_result "Go" updated "$current" "$latest"
  else
    booch_result "Go" current "$current"
  fi
}
