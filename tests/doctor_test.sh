#!/usr/bin/env bash
# lib/doctor.sh のユニットテスト。描画は文字列として、集計・終了コードは状態として検証する。

# stub（command/dpkg 等）は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317
TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/doctor.sh
source "$BOOCH_ROOT/lib/doctor.sh"

# --- booch_ver_norm ---
test_ver_norm_strips_v_prefix() {
  assert_eq "1.2.3" "$(booch_ver_norm "v1.2.3")"
}
test_ver_norm_strips_rust_v_prefix() {
  assert_eq "0.20.0" "$(booch_ver_norm "rust-v0.20.0")"
}
test_ver_norm_strips_build_metadata() {
  assert_eq "1.2.3" "$(booch_ver_norm "1.2.3+build.5")"
}
test_ver_norm_trims_whitespace() {
  assert_eq "1.2.3" "$(booch_ver_norm "  1.2.3  ")"
}
test_ver_norm_leaves_plain_go_version() {
  assert_eq "go1.26.4" "$(booch_ver_norm "go1.26.4")"
}
test_ver_norm_empty() {
  assert_eq "" "$(booch_ver_norm "")"
}
test_ver_norm_all_whitespace() {
  assert_eq "" "$(booch_ver_norm "   ")"
}
test_ver_norm_multiple_plus() {
  assert_eq "1.2" "$(booch_ver_norm "1.2+a+b")"
}
# "1.2.3 (Tool Name)" のような付随語付き --version を最初のトークンに正規化する。
test_ver_norm_drops_trailing_words() {
  assert_eq "2.1.195" "$(booch_ver_norm "2.1.195 (Claude Code)")"
}
# +build と付随語の両方（"0.1.38646+hash (release)" → "0.1.38646"）。
test_ver_norm_drops_build_and_words() {
  assert_eq "0.1.38646" "$(booch_ver_norm "0.1.38646+f96353c (release)")"
}

# --- booch_doctor_tool 分岐 ---
test_doctor_tool_missing_when_current_empty() {
  booch_doctor_init
  local out; out=$(booch_doctor_tool "go" "" "go1.26.4")
  assert_contains "$out" "[MISSING]"
  # フラグは捕捉（$() のサブシェル）では親へ伝わらないため、直接呼んで確認する。
  booch_doctor_init
  booch_doctor_tool "go" "" "go1.26.4" >/dev/null
  assert_eq "1" "$BOOCH_DOCTOR_MISSING"
}
test_doctor_tool_latest_unknown() {
  booch_doctor_init
  local out; out=$(booch_doctor_tool "go" "go1.26.4" "")
  assert_contains "$out" "[OK]"
  assert_contains "$out" "latest: unknown"
}
test_doctor_tool_outdated_when_differ() {
  booch_doctor_init
  local out; out=$(booch_doctor_tool "go" "go1.26.3" "go1.26.4")
  assert_contains "$out" "update available: go1.26.4"
}
test_doctor_tool_ok_when_equal() {
  booch_doctor_init
  local out; out=$(booch_doctor_tool "go" "go1.26.4" "go1.26.4")
  assert_contains "$out" "[OK]"
  assert_not_contains "$out" "update available"
}
# プレフィックス差だけなら正規化で「同じ」とみなし outdated にしない。
test_doctor_tool_ok_when_only_prefix_differs() {
  booch_doctor_init
  local out; out=$(booch_doctor_tool "codex" "rust-v0.20.0" "v0.20.0")
  assert_not_contains "$out" "update available"
  assert_contains "$out" "[OK]"
}

# booch_doctor_tool は捕捉サブシェルで集計を更新しても親へ伝わらないため、
# outdated の集計は row を直接呼んで（同一シェルで）確認する。
test_doctor_row_outdated_sets_flag() {
  booch_doctor_init
  booch_doctor_row "go" outdated "go1.26.3" "go1.26.4" >/dev/null
  assert_eq "1" "$BOOCH_DOCTOR_OUTDATED"
}
test_doctor_row_warn_sets_flag() {
  booch_doctor_init
  booch_doctor_row "x" warn "なんか警告" >/dev/null
  assert_eq "1" "$BOOCH_DOCTOR_WARN"
}
test_doctor_row_skip_renders() {
  booch_doctor_init
  local out; out=$(booch_doctor_row "x" skip "not installed")
  assert_contains "$out" "[SKIP]"
  assert_contains "$out" "not installed"
}
# 未知 status は stderr 診断＋WARN 集計（黙って「all good」に化けさせない）。
test_doctor_row_unknown_status_warns() {
  booch_doctor_init
  local err; err=$(booch_doctor_row "x" bogus "v" 2>&1 >/dev/null)
  assert_contains "$err" "未知"
  booch_doctor_init
  booch_doctor_row "x" bogus "v" >/dev/null 2>&1
  assert_eq "1" "$BOOCH_DOCTOR_WARN"
}

# --- ラベル列幅（BOOCH_DOCTOR_LABEL_WIDTH） ---
# ラベル "go" が幅 w のフィールドに左詰めされ、直後の書式空白 1 つを挟んで [OK] が続く。
# → "go" と "[OK]" の間の空白は (w-2)+1 個になる。期待文字列を計算で組む（目視の桁数固定を避ける）。
_expect_go_ok() { # width
  local w=$1 pad
  pad=$(printf '%*s' "$((w - 2 + 1))" '')
  printf 'go%s[OK]' "$pad"
}
# 既定 30 では 30 桁未満のラベルはパディングで状態列まで隙間が空く。
test_doctor_row_default_width_pads_short_label() {
  booch_doctor_init
  local out; out=$(booch_doctor_row "go" ok "v")
  assert_contains "$out" "$(_expect_go_ok 30)"
}
# env で幅を広げるとパディングが伸びる（既定 30 では出ない幅の空白列になる）。
test_doctor_row_env_widens_padding() {
  booch_doctor_init
  local out; out=$(BOOCH_DOCTOR_LABEL_WIDTH=40 booch_doctor_row "go" ok "v")
  assert_contains "$out" "$(_expect_go_ok 40)"
  assert_not_contains "$out" "$(_expect_go_ok 30)"   # 30 幅では出ない空白列であること
}
# 30 桁超のラベルでも状態が潰れず、ラベルと [OK] の間に区切り空白が残る
# （%-*s なのでフィールドを越えたぶんは押し出され、書式内の空白 1 つは必ず入る）。
test_doctor_row_long_label_not_crushed() {
  booch_doctor_init
  local long="typescript-language-server-and-more-42chars"
  local out; out=$(BOOCH_DOCTOR_LABEL_WIDTH=40 booch_doctor_row "$long" ok "v")
  assert_contains "$out" "$long [OK]"
}
# 非数値 env は既定 30 にフォールバックする（%-*s の幅引数破壊を防ぐ）。
test_doctor_row_nonnumeric_width_falls_back() {
  booch_doctor_init
  local out; out=$(BOOCH_DOCTOR_LABEL_WIDTH=abc booch_doctor_row "go" ok "v")
  assert_contains "$out" "$(_expect_go_ok 30)"
}
# 0 / 負値も既定 30 へフォールバックする。
test_doctor_row_zero_width_falls_back() {
  booch_doctor_init
  local out; out=$(BOOCH_DOCTOR_LABEL_WIDTH=0 booch_doctor_row "go" ok "v")
  assert_contains "$out" "$(_expect_go_ok 30)"
}

# --- 集計とリセット ---
test_doctor_init_resets_flags() {
  BOOCH_DOCTOR_MISSING=1; BOOCH_DOCTOR_OUTDATED=1; BOOCH_DOCTOR_WARN=1
  booch_doctor_init
  assert_eq "0" "$BOOCH_DOCTOR_MISSING"
  assert_eq "0" "$BOOCH_DOCTOR_OUTDATED"
  assert_eq "0" "$BOOCH_DOCTOR_WARN"
}

# --- summary 終了コード ---
test_doctor_summary_returns_1_on_missing() {
  booch_doctor_init
  booch_doctor_row "go" missing >/dev/null
  local rc; if booch_doctor_summary >/dev/null; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}
test_doctor_summary_returns_0_when_clean() {
  booch_doctor_init
  booch_doctor_row "go" ok "go1.26.4" >/dev/null
  local rc; if booch_doctor_summary >/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}
test_doctor_summary_returns_0_on_outdated() {
  booch_doctor_init
  booch_doctor_row "go" outdated "a" "b" >/dev/null
  local out rc
  if out=$(booch_doctor_summary); then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_contains "$out" "outdated"
}
test_doctor_summary_returns_0_on_warn() {
  booch_doctor_init
  booch_doctor_row "x" warn "w" >/dev/null
  local out rc
  if out=$(booch_doctor_summary); then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_contains "$out" "warnings"
}

# --- 色ガード ---
# 色は source 時に一度だけ gate される。対話実行（tty）でも決定論的に検証するため、
# NO_COLOR=1 の別プロセスで source し直してエスケープが出ないことを確認する。
test_doctor_no_color_when_NO_COLOR_set() {
  local out
  out=$(NO_COLOR=1 BOOCH_ROOT="$BOOCH_ROOT" bash -c '
    source "$BOOCH_ROOT/lib/doctor.sh"
    booch_doctor_init
    booch_doctor_row "go" missing "x"')
  assert_not_contains "$out" $'\033['
}

# --- booch_doctor_prefetch ---
test_prefetch_roundtrip() {
  booch_doctor_prefetch_init
  booch_doctor_prefetch foo echo hello
  booch_doctor_prefetch_wait
  assert_eq "hello" "$(booch_doctor_prefetch_get foo)"
  booch_doctor_prefetch_cleanup
}

# パイプラインは bash -c で 1 コマンドとして渡せる。
test_prefetch_pipeline_and_multiple() {
  booch_doctor_prefetch_init
  booch_doctor_prefetch a echo first
  booch_doctor_prefetch b bash -c 'echo "x y" | cut -d" " -f2'
  booch_doctor_prefetch_wait
  assert_eq "first" "$(booch_doctor_prefetch_get a)"
  assert_eq "y" "$(booch_doctor_prefetch_get b)"
  booch_doctor_prefetch_cleanup
}

# cleanup 後は temp ディレクトリが消える。
test_prefetch_cleanup_removes_dir() {
  booch_doctor_prefetch_init
  local dir=$BOOCH_DOCTOR_PREFETCH_DIR
  booch_doctor_prefetch_cleanup
  assert_file_absent "$dir"
}

# --- booch_doctor_apt_pkg（command/dpkg-query/apt-cache/dpkg を seam） ---
test_doctor_apt_pkg_missing() {
  booch_doctor_init
  command() { return 1; }   # コマンド不在
  assert_contains "$(booch_doctor_apt_pkg git git git)" "[MISSING]"
}

test_doctor_apt_pkg_ok_when_candidate_not_newer() {
  booch_doctor_init
  command() { case "$2" in git) return 0 ;; *) builtin command "$@" ;; esac; }
  dpkg-query() { echo "1.0"; }
  apt-cache() { echo "  Candidate: 1.0"; }
  dpkg() { return 1; }   # compare-versions gt → false
  local out; out=$(booch_doctor_apt_pkg git git git)
  assert_contains "$out" "[OK]"
  assert_not_contains "$out" "update available"
}

test_doctor_apt_pkg_outdated_when_candidate_newer() {
  booch_doctor_init
  command() { case "$2" in git) return 0 ;; *) builtin command "$@" ;; esac; }
  dpkg-query() { echo "1.0"; }
  apt-cache() { echo "  Candidate: 2.0"; }
  dpkg() { return 0; }   # compare-versions gt → true
  local out; out=$(booch_doctor_apt_pkg git git git)
  assert_contains "$out" "update available: 2.0"
  # フラグは別実行で確認する（command substitution はサブシェルで状態が消えるため）。
  booch_doctor_init
  booch_doctor_apt_pkg git git git >/dev/null
  assert_eq "1" "$BOOCH_DOCTOR_OUTDATED"
}

# command が空なら dpkg の install 状態で存在判定する（language-pack-ja 等コマンド無し）。
test_doctor_apt_pkg_package_only_ok_when_installed() {
  booch_doctor_init
  dpkg-query() { case "$*" in *Status-Status*) echo "installed" ;; *) echo "1.0" ;; esac; }
  apt-cache() { echo "  Candidate: 1.0"; }
  dpkg() { return 1; }
  local out; out=$(booch_doctor_apt_pkg "language-pack-ja" "" "language-pack-ja")
  assert_contains "$out" "[OK]"
  assert_contains "$out" "1.0"
}
test_doctor_apt_pkg_package_only_missing_when_not_installed() {
  booch_doctor_init
  dpkg-query() { echo ""; }   # 未 install → status 空
  local out; out=$(booch_doctor_apt_pkg "language-pack-ja" "" "language-pack-ja")
  assert_contains "$out" "[MISSING]"
}

# --- booch_doctor_symlinks（temp の実 symlink で検証） ---
test_doctor_symlinks_ok_when_correct() {
  local d; d=$(mktemp -d); : > "$d/src"; ln -s "$d/src" "$d/link"
  assert_contains "$(booch_doctor_symlinks "$d/src|$d/link")" "[OK]"
  rm -rf "$d"
}
test_doctor_symlinks_warn_when_real_file() {
  local d; d=$(mktemp -d); : > "$d/src"; : > "$d/link"
  assert_contains "$(booch_doctor_symlinks "$d/src|$d/link")" "実体が存在"
  rm -rf "$d"
}
test_doctor_symlinks_warn_when_dangling() {
  local d; d=$(mktemp -d); ln -s "$d/nope" "$d/link"
  assert_contains "$(booch_doctor_symlinks "$d/src|$d/link")" "リンク切れ"
  rm -rf "$d"
}
test_doctor_symlinks_warn_when_wrong_target() {
  local d; d=$(mktemp -d); : > "$d/src"; : > "$d/other"; ln -s "$d/other" "$d/link"
  assert_contains "$(booch_doctor_symlinks "$d/src|$d/link")" "別実体"
  rm -rf "$d"
}
test_doctor_symlinks_warn_when_missing() {
  local d; d=$(mktemp -d); : > "$d/src"
  assert_contains "$(booch_doctor_symlinks "$d/src|$d/link")" "未配置"
  rm -rf "$d"
}

# --- booch_doctor_apt_untracked（env gate + apt-mark を seam） ---
test_doctor_apt_untracked_skips_without_env() {
  booch_doctor_init
  local out; out=$(booch_doctor_apt_untracked foo bar)
  assert_contains "$out" "[SKIP]"
  assert_contains "$out" "BOOCH_DOCTOR_APT_AUDIT=1"
}
test_doctor_apt_untracked_lists_untracked_when_enabled() {
  booch_doctor_init
  apt-mark() { printf 'bar\nbaz\nfoo\n'; }
  local out; out=$(BOOCH_DOCTOR_APT_AUDIT=1 booch_doctor_apt_untracked foo)
  assert_contains "$out" "bar"
  assert_contains "$out" "baz"
  assert_not_contains "$out" "      foo"   # 追跡済み foo は一覧に出ない
}
test_doctor_apt_untracked_ok_when_all_tracked() {
  booch_doctor_init
  apt-mark() { printf 'bar\nfoo\n'; }
  assert_contains "$(BOOCH_DOCTOR_APT_AUDIT=1 booch_doctor_apt_untracked foo bar)" "[OK]"
}

run_tests
