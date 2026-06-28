#!/usr/bin/env bash
# tests/ 配下の *_test.sh を個別プロセスで実行し、結果を集計する。
# 各テストファイルはシェル状態（set -u 等）を変えうるため、プロセス分離で隔離する。
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")" || exit 1

fail=0
for f in *_test.sh; do
  echo "=== $f ==="
  bash "$f" || fail=1
  echo ""
done

if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit "$fail"
