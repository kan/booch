#!/usr/bin/env bash
# Codex CLI の設定ヘルパー。~/.codex/config.toml を、リポジトリの config.toml をソースに
# キー単位で冪等更新する。丸ごと上書きせず、ユーザーが足した他キー・セクションを壊さない。
# 何をソースにするか・環境依存キー（model_instructions_file 等の絶対パス）の上書きは利用側が
# 決める（Windows 側 booch-win の lib/codex.ps1 Update-CodexConfig と対称。TOML の書き込みは
# lib/fs.sh の booch_set_toml_key に委譲する）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/fs.sh"     # booch_set_toml_key を使う
#   source "$BOOCH_ROOT/lib/codex.sh"
#   booch_codex_config_sync "$repo/codex/config.toml"                 # → ~/.codex/config.toml
#   booch_set_toml_key "$HOME/.codex/config.toml" model_instructions_file "\"$HOME/AGENTS.md\""
#
# 依存: awk, mkdir, dirname（＋ booch_set_toml_key。lib/fs.sh を先に source すること）。

# TOML のトップレベル `key = value` だけを "key<TAB>value" で 1 行ずつ返す。full parser ではなく
# 用途特化の軽量実装: コメント行・空行を無視し、最初の `[section]` 以降は対象外。値は TOML 表記の
# まま返す（呼び出し側が booch_set_toml_key へそのまま渡せる）。ファイルが無ければ無出力。
booch_codex_config_top_level_keys() { # source_config
  local source_config=$1
  [ -f "$source_config" ] || return 0
  awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*($|#)/ { next }
    /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      key = line
      sub(/[[:space:]]*=.*$/, "", key)
      value = line
      sub(/^[^=]*=[[:space:]]*/, "", value)
      print key "\t" value
    }
  ' "$source_config"
}

# source_config のトップレベルキーで dest（既定 ~/.codex/config.toml）をキー単位に冪等更新する。
# セクション・他キーは温存する（booch_set_toml_key がトップレベルのみ置換/挿入）。source が無ければ
# 何もしない。環境依存キー（絶対パスを含む model_instructions_file 等）は、呼び出し側がこの後に
# booch_set_toml_key で OS 固有値へ上書きする（source 側に値があっても最後の書き込みが勝つ）。
booch_codex_config_sync() { # source_config [dest_config]
  local source_config=$1
  local dest=${2:-$HOME/.codex/config.toml}
  [ -f "$source_config" ] || return 0
  mkdir -p "$(dirname "$dest")"
  local key value
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] || continue
    booch_set_toml_key "$dest" "$key" "$value"
  done < <(booch_codex_config_top_level_keys "$source_config")
}
