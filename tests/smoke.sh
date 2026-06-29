#!/usr/bin/env bash
# runner.sh のエンドツーエンド・スモークテスト。CI（ci.yml）の smoke ステップが実行し、
# ランナーが次をひととおり正しく扱うかを 1 回の booch_run で確認する:
#   - 正常終了 + 実行中ステータス更新（fd 3）
#   - サマリー各種（installed / updated / current / migrated）
#   - 失敗ジョブ（末尾にログ表示・全体は非 0 終了）
#   - タイムアウト（3 秒で kill）
# 失敗ジョブと timeout を含むため、全体は非 0（rc=1）で終了するのが正しい挙動。
# ユニットテスト（tests/run.sh）の代替ではない。利用者向けの使い方サンプルは examples/ を参照。
# 実行: bash tests/smoke.sh

# 各 job_* は booch_job 登録 → runner が bash -c 経由で間接実行する。shellcheck は
# 直接の呼び出しが見えず「到達不能」と誤検知するため、ファイル単位で無効化する。
# shellcheck disable=SC2317
set -uo pipefail

BOOCH_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export BOOCH_ROOT
source "$BOOCH_ROOT/lib/runner.sh"

booch_runner_init

job_install() {
  booch_status "preparing..."
  sleep 1
  booch_status "installing..."
  sleep 1
  booch_result "demo-install" installed "" "1.0.0"
}

job_update() {
  booch_status "checking version..."
  sleep 1
  booch_result "demo-update" updated "1.0.0" "1.1.0"
}

job_current() {
  sleep 1
  booch_result "demo-current" current "2.0.0"
}

job_migrate() {
  booch_status "migrating store..."
  sleep 2
  booch_result "demo-migrate" migrated "old" "new"
}

job_fail() {
  booch_status "doing risky thing..."
  sleep 1
  echo "boom: deliberate failure for demo" >&2
  return 1
}

job_timeout() {
  booch_status "sleeping longer than the timeout..."
  sleep 30
}

booch_job install  "demo: install"  job_install  120
booch_job update   "demo: update"   job_update   120
booch_job current  "demo: current"  job_current  120
booch_job migrate  "demo: migrate"  job_migrate  120
booch_job fail     "demo: fail"     job_fail     120
booch_job timeout  "demo: timeout"  job_timeout  3

booch_run
rc=$?
echo "booch_run exit code: $rc"
exit "$rc"
