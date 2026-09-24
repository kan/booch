#!/usr/bin/env bash
# 最小ユニットテストフレームワーク（外部依存なし）。
# 各テストは test_ で始まる関数として定義し、ファイル末尾で run_tests を呼ぶ。
# run_tests は test_* を「サブシェル + set -e」で隔離実行し、pass/fail を集計する
# （set -e により、テスト内で最初に失敗した assert でそのテストが落ちる）。

fail() { echo "    ASSERT FAIL: $*" >&2; return 1; }

assert_eq() { # expected actual [msg]
  [ "$1" = "$2" ] || fail "${3:-eq}: expected [$1] got [$2]"
}

assert_status() { # expected_rc actual_rc [msg]
  [ "$1" = "$2" ] || fail "${3:-status}: expected exit [$1] got [$2]"
}

assert_contains() { # haystack needle [msg]
  case "$1" in
    *"$2"*) : ;;
    *) fail "${3:-contains}: expected to contain [$2] in:
$1" ;;
  esac
}

assert_not_contains() { # haystack needle [msg]
  case "$1" in
    *"$2"*) fail "${3:-not_contains}: expected NOT to contain [$2] in:
$1" ;;
    *) : ;;
  esac
}

assert_file_absent() { # path [msg]
  [ ! -e "$1" ] || fail "${2:-absent}: expected absent: $1"
}

run_tests() {
  local fns fn out
  mapfile -t fns < <(declare -F | awk '{print $3}' | grep '^test_' | sort)
  local pass=0 failc=0 rc errexit=
  case $- in *e*) errexit=1 ;; esac
  for fn in "${fns[@]}"; do
    # if / || / && の条件の中で実行すると、サブシェル内の set -e が無効になり、最後の行の
    # 終了コードだけで合否が決まる（途中の assert の失敗を見逃す）。条件の外で実行して
    # 終了コードを取る。caller が set -e でも失敗で抜けないよう、この 1 行だけ +e にする。
    set +e
    out=$( set -e; "$fn" 2>&1 ); rc=$?
    [ -z "$errexit" ] || set -e
    if [ "$rc" -eq 0 ]; then
      printf '  ok   %s\n' "$fn"
      pass=$((pass + 1))
    else
      printf '  FAIL %s\n' "$fn"
      [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/      /'
      failc=$((failc + 1))
    fi
  done
  echo ""
  printf '%s: %d passed, %d failed\n' "${0##*/}" "$pass" "$failc"
  [ "$failc" -eq 0 ]
}
