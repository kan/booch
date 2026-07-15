#!/usr/bin/env bash
# autoremove（宣言から外れた実体の掃除）の汎用ドライバ。「実体一覧（stdin）から desired 集合
# （引数）に無いものだけを plan 行にする」差分計算だけを持つ。何を desired とするか・実体をどう
# 列挙するか・plan をどう削除するかは利用側が決める（Windows 側 booch-win の lib/autoremove.ps1 と
# 対称。あちらは PowerShell の性質上オーケストレーション本体まで持つが、bash 側は配列を関数へ
# 渡しにくいため差分計算だけを汎用化し、desired の配線と削除は利用側に残す）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/autoremove.sh"
#   booch_claude_plugin_list | booch_autoremove_diff plugin "リスト外プラグイン" "${DESIRED[@]}"
#     → desired に無い id ごとに "<kind>\t<id>\t<desc>" を 1 行出力（実削除はしない）
#
# 出力の plan 行（"<kind>\t<id>\t<desc>"）は、利用側が確認のうえ kind ごとに削除する
# （Claude 系は booch_claude_autoremove_apply、fs 系は booch_fs_remove_broken_symlink 等）。
#
# 依存: なし（純 bash）。

# stdin の id 一覧（1 行 1 id）から、desired 集合（引数）に無いものを plan 行として出す。
#   booch_autoremove_diff <kind> <desc> <desired...>
# 出力: desired に無い id ごとに "<kind>\t<id>\t<desc>"。空行は読み飛ばす。id の比較は完全一致。
booch_autoremove_diff() { # kind desc desired...
  local kind=$1 desc=$2; shift 2
  local id x found
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    found=0
    for x in "$@"; do
      if [ "$x" = "$id" ]; then found=1; break; fi
    done
    [ "$found" = 1 ] || printf '%s\t%s\t%s\n' "$kind" "$id" "$desc"
  done
}
