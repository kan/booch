#!/usr/bin/env bash
# booch 提供ジョブ: Go ツールチェインの導入 / 更新（非対話）。
#
# 既定で「未導入なら導入、導入済みでも最新と異なれば更新」する。更新可否を人に
# 確認したい場合は、呼び出し側がこのジョブを登録する前に判断する（並列ランナー
# 内では対話できないため、booch のジョブは非対話に保つ）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/arch.sh"
#   source "$BOOCH_ROOT/lib/verify.sh"
#   source "$BOOCH_ROOT/jobs/go.sh"
#   booch_job go "Go" job_go 300      # tarball 取得を含むため timeout は長めに
#
# ツールチェイン導入後に `go install` で入れたい Go ツールがある場合は、空白区切りの
# モジュール一覧を BOOCH_GO_TOOLS に **export** して渡す（ジョブは別プロセスで動くため）。
# job_go が toolchain 導入後・同一ジョブ内で順に install し、モジュールの basename で
# 結果を記録する。例:
#   export BOOCH_GO_TOOLS="github.com/justjanne/powerline-go golang.org/x/tools/gopls"
#
# 依存: lib/arch.sh, lib/verify.sh, curl, tar, sudo（/usr/local/go へ展開する）, uname。
# BOOCH_GO_TOOLS を使う場合は go（PATH 上）と $HOME/go/bin への書込権も要る。
#
# テスト用の継ぎ目（seam）。次の関数を上書きすると、ネットワーク / sudo 無しで
# job_go の分岐（installed / updated / current / 失敗）を検証できる:
#   booch_go_latest_version       最新版文字列を返す（例: go1.22.0）
#   booch_go_installed_version    現在の版を返す（未導入なら空）
#   booch_go_install <version>    実際の導入（副作用）
#   booch_go_expected_sha256 <tarball>  tarball の公式 SHA256 を返す（未取得なら空）
#   booch_go_tool_install <mod>   go install（副作用）
#   booch_go_tool_version <bin>   go ツールの版を返す（未導入なら空）

# 最新の安定版（go.dev が "go1.X.Y" 形式で返す）。
booch_go_latest_version() {
  curl -fsSL --max-time 10 "https://go.dev/VERSION?m=text" | head -1
}

# 導入済みの版（未導入なら空文字）。
booch_go_installed_version() {
  command -v go >/dev/null 2>&1 || return 0
  go version | awk '{print $3}'
}

# Go の配布アーキ名（amd64 / arm64）。lib/arch.sh の dpkg 系ラッパー。
booch_go_arch() { booch_arch_dpkg_style; }

# go.dev が tarball ごとに公開する SHA256（本文は 64 桁 hex のみ）を引く。dl.google.com は
# go.dev/dl の tarball 配布元と同一ホストで、`<tarball>.sha256` を素の hex で返す。
booch_go_expected_sha256() { # tarball
  booch_verify_fetch "https://dl.google.com/go/${1}.sha256" | awk '{print $1; exit}'
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
  # 途中で失敗しても直前の install を手で復旧できるようにするため）。発火時に自身を
  # 解除し、RETURN トラップが呼び出し元へ漏れて再発火するのを防ぐ（呼び出し元の
  # set -u 下で解放済みローカル変数を踏んで落ちないように）。
  trap 'rm -rf "${tmp:-}"; sudo rm -rf "${stage:-}"; trap - RETURN' RETURN

  if ! curl -fsSL "https://go.dev/dl/${tarball}" -o "$tmp/$tarball"; then
    echo "go: tarball の取得に失敗: $tarball" >&2
    return 1
  fi
  # 展開前に公式 SHA256 と照合する。期待値が引けない / 不一致なら導入を止める
  # （sudo で /usr/local/go を触る前に弾く）。
  if ! booch_verify_sha256 "$tmp/$tarball" "$(booch_go_expected_sha256 "$tarball")"; then
    echo "go: tarball の SHA256 検証に失敗: $tarball" >&2
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

# go install で導入するモジュールの版（go version -m のモジュール版）。未導入なら空。
# PATH に出力先（~/go/bin 等）を通していない環境でも拾えるよう、command -v で見つからな
# ければ go install の既定出力先（GOBIN / $(go env GOPATH)/bin）も確認する。
booch_go_tool_version() { # bin
  local bin gobin gopath
  bin=$(command -v "$1" 2>/dev/null)
  if [ -z "$bin" ]; then
    gobin=$(go env GOBIN 2>/dev/null)
    if [ -z "$gobin" ]; then
      gopath=$(go env GOPATH 2>/dev/null)
      [ -n "$gopath" ] && gobin="$gopath/bin"
    fi
    [ -n "$gobin" ] && [ -x "$gobin/$1" ] && bin="$gobin/$1"
  fi
  [ -n "$bin" ] || return 0
  go version -m "$bin" 2>/dev/null | awk '/^[[:space:]]+mod/{print $3; exit}'
}

# モジュールを go install で最新へ導入/更新する（seam）。
booch_go_tool_install() { # module
  go install "${1}@latest"
}

# BOOCH_GO_TOOLS（空白区切りのモジュール一覧）を導入/更新し、basename で結果を記録する。
# toolchain 導入後・同一ジョブ内で呼ぶ（go が PATH に居る前提）。未設定なら何もしない。
booch_go_tools_ensure() {
  local module name old new
  # 意図的に空白で分割してモジュールを列挙する。
  # shellcheck disable=SC2086
  for module in ${BOOCH_GO_TOOLS:-}; do
    name=${module##*/}
    old=$(booch_go_tool_version "$name")
    booch_status "go install ${name}..."
    if ! booch_go_tool_install "$module"; then
      echo "go: ${name} の導入に失敗しました（続行）" >&2
      continue
    fi
    new=$(booch_go_tool_version "$name")
    if [ -z "$old" ]; then
      booch_result "$name" installed "" "$new"
    elif [ "$old" != "$new" ]; then
      booch_result "$name" updated "$old" "$new"
    else
      booch_result "$name" current "$new"
    fi
  done
}

job_go() {
  local current latest
  current=$(booch_go_installed_version)
  latest=$(booch_go_latest_version)
  if [ -z "$latest" ]; then
    echo "go: 最新版の取得に失敗しました" >&2
    return 1
  fi

  booch_job_sync "Go" "" "$current" "$latest" booch_go_install "$latest"

  # caller 指定の go ツール（powerline-go / gopls 等）を toolchain 導入後に入れる。
  booch_go_tools_ensure
}
