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
# 依存: ln, readlink, mkdir, mv, awk, date, touch, mktemp（GNU coreutils）。

# src を指す symlink を dest に作る（冪等）。
#   dest が同じ src を指す symlink     → 何もしない
#   dest が別を指す symlink            → 張り替える
#   dest が symlink でない実体         → <dest>.bak へ退避してから張る
#   dest が無い                        → 親ディレクトリを作って張る
booch_symlink() { # src dest
  local src=$1 dest=$2
  if [ -L "$dest" ]; then
    # 解決後どうしのパスで比較する。生 src と readlink -f(dest) を比べると、src が
    # symlink 親配下や相対パスのとき毎回「更新」になり冪等性が崩れるため。
    if [ "$(readlink -f "$dest" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ]; then
      echo "symlink 済み: $dest"
    else
      ln -sfn "$src" "$dest"
      echo "symlink 更新: $dest -> $src"
    fi
  elif [ -e "$dest" ]; then
    # 実体は退避してから張る。既存の .bak は上書きしない（最初のバックアップを壊さないよう、
    # 既にあればタイムスタンプ付きの別名へ退避する）。
    local bak="${dest}.bak"
    [ -e "$bak" ] && bak="${dest}.bak.$(date +%Y%m%d%H%M%S)"
    echo "警告: $dest は symlink ではありません。${bak} へ退避します" >&2
    mv "$dest" "$bak"
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
# 親ディレクトリが無ければ作る（初回配置で touch が失敗しないように）。key/value は
# リテラル扱いで、regex/置換のメタ文字（. [ & | \ 等）を解釈させない（sed だと誤置換・
# 構文エラーになりうるため awk で 1 パス置換/追記する）。
booch_set_toml_key() { # file key value
  local file=$1 key=$2 value=$3 tmp rc
  mkdir -p "$(dirname "$file")" || return 1
  touch "$file" || return 1
  tmp=$(mktemp) || return 1
  awk -v k="$key" -v v="$value" '
    BEGIN { kv = k " = " v }
    {
      probe = $0
      sub(/^[ \t]+/, "", probe)
      sub(/[ \t]*=.*$/, "", probe)
      if (probe == k && !done) { print kv; done = 1 } else { print $0 }
    }
    END { if (!done) print kv }
  ' "$file" > "$tmp" && cat "$tmp" > "$file"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}
