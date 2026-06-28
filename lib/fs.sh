#!/usr/bin/env bash
# ファイルシステム系の汎用ユーティリティ。設定ファイルの symlink 配置と、TOML のキー単位
# 冪等更新。どちらも sudo / network 不要の純粋な fs 操作で、利用側は「どこへ何を」だけを
# 決める。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/fs.sh"
#   booch_symlink "$repo/bash/bashrc" "$HOME/.bashrc"
#   booch_set_toml_key "$HOME/.codex/config.toml" model '"gpt-5.4"'
#
# 依存: ln, readlink, mkdir, mv, grep, sed, touch（GNU coreutils）。

# src を指す symlink を dest に作る（冪等）。
#   dest が同じ src を指す symlink     → 何もしない
#   dest が別を指す symlink            → 張り替える
#   dest が symlink でない実体         → <dest>.bak へ退避してから張る
#   dest が無い                        → 親ディレクトリを作って張る
booch_symlink() { # src dest
  local src=$1 dest=$2 current
  if [ -L "$dest" ]; then
    current=$(readlink -f "$dest" 2>/dev/null || true)
    if [ "$current" = "$src" ]; then
      echo "symlink 済み: $dest"
    else
      ln -sfn "$src" "$dest"
      echo "symlink 更新: $dest -> $src"
    fi
  elif [ -e "$dest" ]; then
    echo "警告: $dest は symlink ではありません。${dest}.bak へ退避します" >&2
    mv "$dest" "${dest}.bak"
    ln -s "$src" "$dest"
    echo "symlink 作成: $dest -> $src"
  else
    mkdir -p "$(dirname "$dest")"
    ln -s "$src" "$dest"
    echo "symlink 作成: $dest -> $src"
  fi
}

# TOML のキーを冪等に設定する。既にあれば値を置換、無ければ追記する。他キーには触れない
# （ユーザーが足した他キーを壊さないため、丸ごと上書きしない用途に使う）。
booch_set_toml_key() { # file key value
  local file=$1 key=$2 value=$3
  touch "$file"
  if grep -Eq "^${key}[[:space:]]*=" "$file"; then
    sed -i "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "$file"
  else
    echo "${key} = ${value}" >> "$file"
  fi
}
