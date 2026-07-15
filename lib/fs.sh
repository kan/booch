#!/usr/bin/env bash
# ファイルシステム系の汎用ユーティリティ。設定ファイルの symlink 配置と、TOML のキー単位
# 冪等更新。どちらも sudo / network 不要の純粋な fs 操作で、利用側は「どこへ何を」だけを
# 決める。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/fs.sh"
#   booch_symlink "$repo/bash/bashrc" "$HOME/.bashrc"
#   booch_set_toml_key "$HOME/.codex/config.toml" model '"gpt-5.4"'
#   booch_fs_broken_symlinks "$HOME/.local/bin" "$HOME/.config"   # "dest<TAB>target" を列挙
#   booch_fs_remove_broken_symlink "$HOME/.local/bin/foo"          # 壊れリンクだけ再検証して削除
#
# 依存: ln, readlink, mkdir, mv, awk, date, touch, mktemp, find（GNU coreutils）。

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

# TOML の「トップレベル」キーを冪等に設定する。既にあれば値を置換、無ければ追記する。他キーには
# 触れない（ユーザーが足した他キーを壊さないため、丸ごと上書きしない用途に使う）。
# 親ディレクトリが無ければ作る（初回配置で touch が失敗しないように）。key/value は
# リテラル扱いで、regex/置換のメタ文字（. [ & | \ 等）を解釈させない（sed だと誤置換・
# 構文エラーになりうるため awk で 1 パス置換/追記する）。
#
# セクション対応（重要）: 対象はあくまでトップレベルのキー。最初の `[section]` ヘッダより前
# （トップレベル領域）だけを置換・挿入対象にする。トップレベルに未存在で、かつファイルが
# セクションを含む場合、EOF ではなく最初のセクションヘッダの直前に挿入する（EOF 追記だと
# 末尾のセクション内に入り込み、キーが `[section].key` として解釈されて無効化するため）。
# セクション内の同名キーには触れない。
booch_set_toml_key() { # file key value
  local file=$1 key=$2 value=$3 tmp rc
  mkdir -p "$(dirname "$file")" || return 1
  touch "$file" || return 1
  tmp=$(mktemp) || return 1
  awk -v k="$key" -v v="$value" '
    BEGIN { kv = k " = " v; done = 0; in_top = 1 }
    {
      hdr = $0
      sub(/^[ \t]+/, "", hdr)
      # トップレベル領域の終わり（最初のセクションヘッダ）。未挿入ならここで挿入する。
      if (in_top && substr(hdr, 1, 1) == "[") {
        if (!done) { print kv; done = 1 }
        in_top = 0
        print $0
        next
      }
      # トップレベル領域内で同名キーがあれば置換する（セクション内は対象外）。
      if (in_top && !done) {
        probe = $0
        sub(/^[ \t]+/, "", probe)
        sub(/[ \t]*=.*$/, "", probe)
        if (probe == k) { print kv; done = 1; next }
      }
      print $0
    }
    END { if (!done) print kv }
  ' "$file" > "$tmp" && cat "$tmp" > "$file"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# root（複数、直下のみ maxdepth 1）から壊れた symlink を "dest\ttarget" で 1 行ずつ返す。
# 生きているリンク・非リンク・読めないリンクは対象外（列挙のみ。実体は消さない）。どの target を
# 掃除対象とするか（自分が配置したものだけ、等）の絞り込みは利用側が行う。$HOME 直下など user 自作
# リンクが混じる場所を巻き込まないよう、走査は maxdepth 1（root 直下）に限る。
booch_fs_broken_symlinks() { # root...
  local root link tgt
  for root in "$@"; do
    [ -d "$root" ] || continue
    while IFS= read -r link; do
      [ -e "$link" ] && continue                  # 生きているリンクは対象外
      tgt=$(readlink "$link" 2>/dev/null) || continue
      printf '%s\t%s\n' "$link" "$tgt"
    done < <(find "$root" -maxdepth 1 -type l 2>/dev/null)
  done
}

# symlink かつ壊れている（指す先が存在しない）ことを再検証してから削除する。生きたリンク・実体は
# 消さない（apply 直前の TOCTOU 対策として再検証する）。成功で 0。
booch_fs_remove_broken_symlink() { # dest
  [ -L "$1" ] || return 1
  [ -e "$1" ] && return 1
  rm -f "$1"
}
