#!/usr/bin/env bash
# 色（ANSI エスケープ）の共通定義。stdout が tty かつ NO_COLOR 未設定のときだけ色を使い、
# パイプ / CI / ログ捕捉にエスケープを混ぜない。色を使う lib（runner.sh / doctor.sh 等）が
# source する。複数回 source しても同じ値を再設定するだけで安全。
#
#   _BOOCH_COLOR_{RED,YELLOW,GREEN,CYAN,DIM,RESET}
#
# gate は source 時に一度だけ評価される（出力先が決まっている前提）。

# これらは他ファイルから参照される公開変数（本ファイル内では代入のみ）。
# shellcheck disable=SC2034
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _BOOCH_COLOR_RED=$'\033[1;31m'
  _BOOCH_COLOR_YELLOW=$'\033[1;33m'
  _BOOCH_COLOR_GREEN=$'\033[1;32m'
  _BOOCH_COLOR_CYAN=$'\033[36m'
  _BOOCH_COLOR_DIM=$'\033[2m'
  _BOOCH_COLOR_RESET=$'\033[0m'
else
  _BOOCH_COLOR_RED=''; _BOOCH_COLOR_YELLOW=''; _BOOCH_COLOR_GREEN=''
  _BOOCH_COLOR_CYAN=''; _BOOCH_COLOR_DIM=''; _BOOCH_COLOR_RESET=''
fi
