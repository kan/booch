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
# 依存: npm。
#
# テスト用の継ぎ目（seam）:
#   booch_npm_present          npm が PATH にあるか（利用側が事前確認に使う）
#   booch_npm_run <args...>    npm を実行

: "${BOOCH_NPM_PREFIX:=$HOME/.local}"

booch_npm_present() { command -v npm >/dev/null 2>&1; }
booch_npm_run() { npm "$@"; }

# src の npm プロジェクト（package.json と、あれば package-lock.json）を dest へ同期し、
# dest で install する。固有の設定ファイルは利用側がこの後で配置する。
booch_npm_local_install() { # src_dir dest_dir
  local src=$1 dest=$2
  if [ ! -f "$src/package.json" ]; then
    echo "npm: package.json がありません: $src" >&2
    return 1
  fi
  mkdir -p "$dest" || return 1
  cp "$src/package.json" "$dest/" || return 1
  if [ -f "$src/package-lock.json" ]; then
    cp "$src/package-lock.json" "$dest/" || return 1
  fi
  # cwd を汚さず dest で install するためサブシェルで cd。サブシェルが関数最後の文
  # なので、その rc（install の成否）がそのまま関数の戻り値になる。
  ( cd "$dest" && booch_npm_run install --no-audit --no-fund )
}

# ユーザー prefix へグローバル install / 更新する（sudo 不要）。グローバルの安価な
# 「導入済み?」判定が無いため毎回 install する（npm install -g は冪等。ただし
# オフライン再実行は失敗しうる）。
booch_npm_global_ensure() { # pkg...
  booch_npm_run install -g --prefix "$BOOCH_NPM_PREFIX" "$@"
}
