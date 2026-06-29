#!/usr/bin/env bash
# sudo の事前キャッシュとキープアライブ。
#
# 並列ジョブの多くが sudo を使う場合、並列実行ではパスワードプロンプトが複数同時に出て
# 衝突し、入力する前に各 sudo が失敗して走り抜けてしまう（ランナーはジョブの stdin を
# /dev/null にし、tty 入力も待たないため）。これを避けるため、並列実行の前に sudo 認証を
# 一度だけ取得してキャッシュし、実行中はバックグラウンドで更新し続けて、各ジョブの sudo を
# プロンプト無しで通す。
#
# 使い方:
#   booch_sudo_prime || exit 1     # 認証（対話で 1 回プロンプト）+ キープアライブ開始
#   booch_run                       # 並列実行（各ジョブの sudo はキャッシュで通る）
#   booch_sudo_stop                 # キープアライブ停止
#
# 依存: sudo, pkill（procps）。
#
# テスト用の継ぎ目（seam）:
#   booch_sudo_validate   認証情報を取得/更新する（sudo -v 相当。対話プロンプトしうる）
#   booch_sudo_refresh    認証情報を非対話で更新する（sudo -n true 相当）

BOOCH_SUDO_KEEPALIVE_PID=""

booch_sudo_validate() { sudo -v; }
booch_sudo_refresh() { sudo -n true 2>/dev/null; }

# 認証をキャッシュし、キープアライブを開始する。認証に失敗したら非 0。
# booch は再実行前提のため、二重起動で前回の keepalive を孤児にしないよう、開始前に必ず
# 既存のキープアライブを止める。
booch_sudo_prime() {
  booch_sudo_stop
  booch_sudo_validate || return 1
  # 長い並列実行中にタイムスタンプが切れないよう更新し続ける。更新できなくなったら
  # （認証取り消し等）ループを抜けてキープアライブを終える。
  ( while booch_sudo_refresh; do sleep 50; done ) &
  BOOCH_SUDO_KEEPALIVE_PID=$!
}

# キープアライブを停止する。サブシェル本体だけでなく、その子（sleep）も落とす
# （kill だけだと sleep が最大 50 秒残る）。
booch_sudo_stop() {
  [ -n "$BOOCH_SUDO_KEEPALIVE_PID" ] || return 0
  kill "$BOOCH_SUDO_KEEPALIVE_PID" 2>/dev/null
  pkill -P "$BOOCH_SUDO_KEEPALIVE_PID" 2>/dev/null
  BOOCH_SUDO_KEEPALIVE_PID=""
}
