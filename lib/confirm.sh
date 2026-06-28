#!/usr/bin/env bash
# 対話確認のフレーム。並列ジョブは非対話だが、「更新があるときだけ確認する」という判断は
# ジョブ登録の前（booch_run の前、対話可能な親シェル）で共通化できる。本ヘルパーはその
# 判断と tty プロンプトだけを担い、実際に何を登録するかは呼び出し側が戻り値で分岐する。
# （ジョブ内ではなく登録時に使うもの。ジョブは非対話のまま。）
#
# booch_confirm_update LABEL CURRENT LATEST [ASSUME_YES]
#   戻り値 0 = 進めてよい（登録する）、1 = 見送る。
#     CURRENT 空（未導入）      → 0（確認なしで導入）
#     ASSUME_YES が真          → 0（確認省略。true / yes / 1）
#     LATEST 空（版不明）       → 1（ネット不調等を failed にせず現状維持）+ メッセージ
#     CURRENT == LATEST        → 0（最新。ジョブは current を報告するだけ）
#     異なる                    → tty があれば y/N 確認（yes→0 / no→1）。tty 無しは見送り（1）
#
# 使い方:
#   booch_confirm_update "Go" "$cur" "$latest" "$ASSUME_YES" && booch_job go "Go" job_go 300
#
# テスト用の継ぎ目（seam）:
#   booch_confirm_prompt LABEL CURRENT LATEST   実際の y/N プロンプト（yes→0 / それ以外→1）

# tty があるときだけ y/N を尋ねる。非対話（CI / パイプ）では /dev/tty を開けないので、
# その診断を出さずに probe してから read する（無ければ no 扱い）。
booch_confirm_prompt() { # label current latest
  local ans=""
  if { true >/dev/tty; } 2>/dev/null; then
    read -rp "$1 の更新があります: $2 -> $3。更新しますか? [y/N] " ans </dev/tty || ans=""
  fi
  [[ $ans =~ ^[Yy]$ ]]
}

booch_confirm_update() { # label current latest [assume_yes]
  local label=$1 current=$2 latest=$3 assume_yes=${4:-false}

  [ -z "$current" ] && return 0
  case "$assume_yes" in true | yes | 1) return 0 ;; esac

  if [ -z "$latest" ]; then
    echo "$label: 最新版を確認できませんでした（$current のまま）"
    return 1
  fi
  [ "$current" = "$latest" ] && return 0

  if booch_confirm_prompt "$label" "$current" "$latest"; then
    return 0
  fi
  echo "$label: 更新をスキップしました（$current のまま）"
  return 1
}
