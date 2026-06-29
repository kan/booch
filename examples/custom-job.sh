#!/usr/bin/env bash
# 利用側 dotfiles から booch を source し、自分用の custom job を登録する最小サンプル。
# 個人固有・業務固有の処理（特定リポジトリの clone/pull・社内ツール・トークン投入など）は
# booch 本体に入れず、こうして利用側にとどめる。booch は並列ランナーと汎用ジョブだけを担う。
#
# 実行: bash examples/custom-job.sh
#   （実運用では dotfiles が BOOCH_ROOT を知っている前提。未設定ならこのファイルから推定する）

# job_* は runner が bash -c 経由で間接実行するため shellcheck には到達不能に見える。
# shellcheck disable=SC2317
set -uo pipefail

: "${BOOCH_ROOT:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export BOOCH_ROOT
source "$BOOCH_ROOT/lib/runner.sh"

booch_runner_init

# custom job: 自分用の設定ディレクトリを用意する（個人固有なので利用側に置く）。
# ジョブは非対話・別プロセスで動くため、依存できるのは exported 変数と関数定義だけ。
job_myconfig() {
  booch_status "preparing ~/.config/myapp ..."
  local dir="$HOME/.config/myapp"
  if [ -d "$dir" ]; then
    booch_result "myapp config" current "(exists)"
  else
    mkdir -p "$dir"
    booch_result "myapp config" installed "" "created"
  fi
}

booch_job myconfig "myapp config" job_myconfig 60
booch_run
