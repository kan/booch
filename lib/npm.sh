#!/usr/bin/env bash
# npm ヘルパー。ローカル npm プロジェクト（package.json）を実行用ディレクトリへ同期して
# install する処理と、ユーザー prefix へのグローバル install を共通化する。
#
# どのパッケージを入れるか・固有の設定ファイル（例: textlint の .textlintrc.json）の配置は
# 持ち込まない。利用側が選んで呼ぶ（issue #1 の「汎用ヘルパー＋個人設定」分割）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/npm.sh"
#   booch_npm_local_install "$repo/textlint" "$HOME/.config/textlint-mcp-server"
#   booch_npm_global_ensure typescript-language-server typescript
#
# グローバルは sudo 不要で BOOCH_NPM_PREFIX（既定 ~/.local）の bin に入る。
#
# スコープ注記: local install は package.json（+ package-lock.json）だけを同期する。
# .npmrc / workspaces は同期せず、`npm install`（`npm ci` ではない）で入れる。private
# registry や厳密なロック固定が要る用途は対象外。booch_npm_present は内部では使わない
# （npm の有無確認は利用側の責務。seam として公開する）。
#
# 版の追従は src の package-lock.json の有無で決まる（booch_npm_local_install 参照）:
#   src に lock あり → その固定どおり（install のみ）
#   src に lock なし → package.json のレンジ内で最新へ追従（install 後に update）
#
# 依存: npm。
#
# テスト用の継ぎ目（seam）:
#   booch_npm_present          npm が PATH にあるか（利用側が事前確認に使う）
#   booch_npm_run <args...>    npm を実行

# runner の bash -c 子（ジョブ）から参照できるよう export する（非 export だと
# ジョブ内で空になり global install の --prefix が壊れる）。
: "${BOOCH_NPM_PREFIX:=$HOME/.local}"
export BOOCH_NPM_PREFIX

booch_npm_present() { command -v npm >/dev/null 2>&1; }
booch_npm_run() { npm "$@"; }

# src の npm プロジェクト（package.json と、あれば package-lock.json）を dest へ同期し、
# dest で install する。固有の設定ファイルは利用側がこの後で配置する。
#
# src が package-lock.json を持たないときは install に続けて update も走らせる。dest の
# lockfile は初回 install の副産物として残るが、`npm install` は**それがレンジを満たす限り
# 古い版を保持する**ため、package.json のレンジ内に新版が出ても永久に前進しなくなる
# （dotfiles の textlint が ^15.7.1 のまま 15.8.0 へ上がらなかった実例）。src に lockfile が
# 無い＝版を固定する意図が無いので、update でレンジ内最新へ追従させる。レンジ外（メジャー
# 跨ぎ）は動かないので、package.json の手 bump が要る点は変わらない。
booch_npm_local_install() { # src_dir dest_dir
  local src=$1 dest=$2
  if [ ! -f "$src/package.json" ]; then
    echo "npm: package.json がありません: $src" >&2
    return 1
  fi
  mkdir -p "$dest" || return 1
  cp "$src/package.json" "$dest/" || return 1
  # src の lockfile は「意図された版固定」の signal。あるときは尊重して update しない。
  local pinned=""
  if [ -f "$src/package-lock.json" ]; then
    cp "$src/package-lock.json" "$dest/" || return 1
    pinned=1
  fi
  # cwd を汚さず dest で install するためサブシェルで cd。サブシェルが関数最後の文
  # なので、その rc（install / update の成否）がそのまま関数の戻り値になる。
  (
    cd "$dest" || exit 1
    booch_npm_run install --no-audit --no-fund || exit
    [ -n "$pinned" ] || booch_npm_run update --no-audit --no-fund
  )
}

# ユーザー prefix へグローバル install / 更新する（sudo 不要）。グローバルの安価な
# 「導入済み?」判定が無いため毎回 install する（npm install -g は冪等。ただし
# オフライン再実行は失敗しうる）。
booch_npm_global_ensure() { # pkg...
  booch_npm_run install -g --prefix "$BOOCH_NPM_PREFIX" "$@"
}
