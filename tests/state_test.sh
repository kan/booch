#!/usr/bin/env bash
# lib/state.sh のユニットテスト。BOOCH_STATE_DIR を temp ディレクトリへ向けて、記録と判定を検証する。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/state.sh
source "$BOOCH_ROOT/lib/state.sh"

# 各テストは run_tests の $( ) サブシェルで動くので、置き場の差し替えも trap も他のテストへ
# 漏れない。trap で消すのは、assert が落ちて途中で抜けたときも temp を残さないため。
_use_temp_state_dir() {
  BOOCH_STATE_DIR=$(mktemp -d)
  # shellcheck disable=SC2064  # 今の値で消す（後から変数を書き換えても消す対象は変えない）
  trap "rm -rf '$BOOCH_STATE_DIR'" EXIT
}

# _booch_state_file は結果を変数へ返すので、比べやすいよう標準出力へ出す。
_path_of() { # id
  local p; _booch_state_file p "$1"; printf '%s' "$p"
}

# --- 置き場 ---
test_state_dir_defaults_to_xdg_cache() {
  unset BOOCH_STATE_DIR
  XDG_CACHE_HOME=/x/cache
  assert_eq /x/cache/booch/state/t "$(_path_of t)"
}

test_state_dir_falls_back_to_home_cache() {
  unset BOOCH_STATE_DIR XDG_CACHE_HOME
  HOME=/h
  assert_eq /h/.cache/booch/state/t "$(_path_of t)"
}

test_state_dir_uses_caller_value() {
  BOOCH_STATE_DIR=/mine
  assert_eq /mine/t "$(_path_of t)"
}

# source しただけで利用側の環境へ変数を出さない。
test_source_does_not_export_state_dir() {
  local got
  got=$(unset BOOCH_STATE_DIR; bash -c 'source "$1"; env | grep -c "^BOOCH_STATE_DIR=" || true' _ "$BOOCH_ROOT/lib/state.sh")
  assert_eq 0 "$got"
}

# --- 記録ファイルの名前 ---
test_safe_id_keeps_plain_name() {
  BOOCH_STATE_DIR=/s
  assert_eq /s/doctor-daily.v2_x "$(_path_of doctor-daily.v2_x)"
}

test_unsafe_chars_are_percent_encoded() {
  BOOCH_STATE_DIR=/s
  assert_eq /s/a%2Fb%20c%3Ad%25 "$(_path_of 'a/b c:d%')"
}

# 潰すだけだと同じ名前になる id どうしを取り違えない。
test_ids_colliding_after_naive_sanitize_are_distinct() {
  _use_temp_state_dir
  booch_state_touch 'a:b'
  if booch_state_fresh 'a/b' 3600; then fail "a:b の touch で a/b が fresh になった"; fi
  if booch_state_fresh a_b 3600; then fail "a:b の touch で a_b が fresh になった"; fi
}

# 先頭の . は符号化する（隠しファイルや . / .. にしない）。途中の . はそのまま。
test_leading_dot_is_encoded() {
  BOOCH_STATE_DIR=/s
  assert_eq /s/%2E. "$(_path_of ..)"
  assert_eq /s/%2Ea.b "$(_path_of .a.b)"
}

test_empty_id_does_not_point_to_state_dir() {
  BOOCH_STATE_DIR=/s
  assert_eq /s/% "$(_path_of "")"
}

# マルチバイト文字はバイト単位で符号化する。
test_multibyte_id_is_encoded_by_bytes() {
  BOOCH_STATE_DIR=/s
  assert_eq /s/%E3%81%82 "$(_path_of あ)"
}

# --- booch_hash_args ---
test_hash_args_is_sha256_of_nul_joined_args() {
  assert_eq "$(printf 'a\0b\0' | sha256sum | cut -d' ' -f1)" "$(booch_hash_args a b)"
}

# 区切りが NUL なので、引数の切れ目が違えば別のハッシュになる。
test_hash_args_keeps_argument_boundaries() {
  local h1 h2
  h1=$(booch_hash_args "a b" c)
  h2=$(booch_hash_args a "b c")
  [ "$h1" != "$h2" ] || fail "引数の切れ目が違うのに同じハッシュになった"
}

test_hash_args_empty_without_sha256sum() {
  local got
  got=$(PATH=/nonexistent booch_hash_args a)
  assert_eq "" "$got"
}

# --- booch_state_changed / booch_state_record ---
test_changed_when_not_recorded() {
  _use_temp_state_dir
  booch_state_changed t "$(booch_hash_args x)" || fail "未記録なのに「変わっていない」と判定した"
}

test_not_changed_after_record() {
  _use_temp_state_dir
  local h; h=$(booch_hash_args x)
  booch_state_record t "$h"
  if booch_state_changed t "$h"; then fail "記録したのに「変わった」と判定した"; fi
}

# 未記録で記録の読み込みが失敗しても、set -e の下（run_tests はテストを set -e で走らせる）で
# 途中終了せず「変わった」（0）を返す。条件の外で呼ぶので、非 0 ならこの行でテストが落ちる。
test_changed_when_not_recorded_under_errexit() {
  _use_temp_state_dir
  booch_state_changed t "$(booch_hash_args x)"
}

# 記録の末尾に改行が無くても、同じ hash なら「変わっていない」。
test_not_changed_when_record_lacks_newline() {
  _use_temp_state_dir
  local h; h=$(booch_hash_args x)
  mkdir -p "$BOOCH_STATE_DIR"; printf '%s' "$h" > "$BOOCH_STATE_DIR/t"
  if booch_state_changed t "$h"; then fail "改行の無い記録を「変わった」と判定した"; fi
}

test_changed_when_hash_differs() {
  _use_temp_state_dir
  booch_state_record t "$(booch_hash_args x)"
  booch_state_changed t "$(booch_hash_args y)" || fail "hash が違うのに「変わっていない」と判定した"
}

# ハッシュを取れない環境では処理を飛ばさない側へ倒す。記録も残さない。
test_empty_hash_is_always_changed_and_not_recorded() {
  _use_temp_state_dir
  booch_state_record t ""
  assert_file_absent "$BOOCH_STATE_DIR/t"
  booch_state_changed t "" || fail "空の hash なのに「変わっていない」と判定した"
}

test_record_creates_state_dir() {
  _use_temp_state_dir
  BOOCH_STATE_DIR="$BOOCH_STATE_DIR/deep/state"
  booch_state_record t "$(booch_hash_args x)"
  [ -f "$BOOCH_STATE_DIR/t" ] || fail "置き場を作らずに記録しようとした"
}

# --- booch_state_fresh / booch_state_touch ---
test_not_fresh_when_never_touched() {
  _use_temp_state_dir
  if booch_state_fresh t 3600; then fail "未記録なのに fresh と判定した"; fi
}

test_fresh_right_after_touch() {
  _use_temp_state_dir
  booch_state_touch t
  booch_state_fresh t 3600 || fail "touch 直後なのに fresh でない"
}

test_not_fresh_when_max_age_zero() {
  _use_temp_state_dir
  booch_state_touch t
  if booch_state_fresh t 0; then fail "max_age 0 なのに fresh と判定した"; fi
}

test_not_fresh_when_older_than_max_age() {
  _use_temp_state_dir
  booch_state_touch t
  touch -d '2 hours ago' "$BOOCH_STATE_DIR/t"
  if booch_state_fresh t 3600; then fail "max_age を過ぎたのに fresh と判定した"; fi
}

# 時計が進んだ状態で touch された記録（mtime が未来）は古い扱いにする。
test_not_fresh_when_mtime_in_future() {
  _use_temp_state_dir
  booch_state_touch t
  touch -d '2 hours' "$BOOCH_STATE_DIR/t"
  if booch_state_fresh t 86400; then fail "mtime が未来なのに fresh と判定した"; fi
}

run_tests
