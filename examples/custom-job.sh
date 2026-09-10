#!/usr/bin/env bash
# 利用側 dotfiles から booch を source し、自分用の custom job を登録する最小サンプル。
# 個人固有・業務固有の処理（特定リポジトリの clone/pull・社内ツール・トークン投入など）は
# booch 本体に入れず、こうして利用側にとどめる。booch は並列ランナーと汎用ジョブだけを担う。
#
# 実行: bash examples/custom-job.sh
#   （実運用では dotfiles が BOOCH_ROOT を知っている前提。未設定ならこのファイルから推定する）
#   書き込み先は実 $HOME ではなく一時ディレクトリ配下。2 回目の実行は current になる（冪等）。
#   片付け: rm -rf "${TMPDIR:-/tmp}/booch-example"

# job_* は runner が bash -c 経由で間接実行するため shellcheck には到達不能に見える。
# shellcheck disable=SC2317
set -uo pipefail

: "${BOOCH_ROOT:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export BOOCH_ROOT
source "$BOOCH_ROOT/lib/runner.sh"

booch_runner_init

# 対象パス。実運用では "$HOME/.config/myapp" のような実パスを書く。サンプルなので一時
# ディレクトリ配下にし、2 回目の実行が current になるよう mktemp -d ではなく固定パスにする。
export MYAPP_CONFIG_DIR="${TMPDIR:-/tmp}/booch-example/myapp"

# custom job: 自分用の設定ディレクトリを用意する（個人固有なので利用側に置く）。
# ジョブは非対話・別プロセスで動くため、依存できるのは exported 変数と関数定義だけ。
job_myconfig() {
  booch_status "preparing $MYAPP_CONFIG_DIR ..."
  if [ -d "$MYAPP_CONFIG_DIR" ]; then
    booch_result "myapp config" current "(exists)"
  else
    mkdir -p "$MYAPP_CONFIG_DIR"
    booch_result "myapp config" installed "" "created"
  fi
}

booch_job myconfig "myapp config" job_myconfig 60
booch_run
