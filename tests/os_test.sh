#!/usr/bin/env bash
# lib/os.sh のユニットテスト。fixture の os-release を食わせて検出結果を検証する。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# shellcheck source=lib/os.sh
source "$BOOCH_ROOT/lib/os.sh"

# 一時 os-release を書いて booch_detect_os に渡す。
_write_os_release() {
  local f; f=$(mktemp)
  cat > "$f"
  printf '%s' "$f"
}

test_os_ubuntu_2604() {
  local f
  f=$(_write_os_release <<'EOF'
ID=ubuntu
VERSION_ID="26.04"
VERSION_CODENAME=resolute
UBUNTU_CODENAME=resolute
EOF
)
  booch_detect_os "$f"
  rm -f "$f"
  assert_eq "ubuntu"   "$BOOCH_OS_ID"
  assert_eq "26.04"    "$BOOCH_OS_VERSION_ID"
  assert_eq "26"       "$BOOCH_OS_VERSION_MAJOR"
  assert_eq "resolute" "$BOOCH_OS_CODENAME"
}

# 両方ある場合は VERSION_CODENAME を優先する（値を変えて優先順位を実証する）。
test_os_codename_prefers_version_codename() {
  local f
  f=$(_write_os_release <<'EOF'
ID=ubuntu
VERSION_ID="26.04"
VERSION_CODENAME=resolute
UBUNTU_CODENAME=noble
EOF
)
  booch_detect_os "$f"
  rm -f "$f"
  assert_eq "resolute" "$BOOCH_OS_CODENAME"
}

# VERSION_CODENAME が無いときは UBUNTU_CODENAME にフォールバックする。
test_os_codename_fallback_to_ubuntu_codename() {
  local f
  f=$(_write_os_release <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
UBUNTU_CODENAME=noble
EOF
)
  booch_detect_os "$f"
  rm -f "$f"
  assert_eq "noble" "$BOOCH_OS_CODENAME"
  assert_eq "24"    "$BOOCH_OS_VERSION_MAJOR"
}

test_os_non_ubuntu_debian() {
  local f
  f=$(_write_os_release <<'EOF'
ID=debian
VERSION_ID="12"
VERSION_CODENAME=bookworm
EOF
)
  booch_detect_os "$f"
  rm -f "$f"
  assert_eq "debian"   "$BOOCH_OS_ID"
  assert_eq "12"       "$BOOCH_OS_VERSION_ID"
  assert_eq "12"       "$BOOCH_OS_VERSION_MAJOR"
  assert_eq "bookworm" "$BOOCH_OS_CODENAME"
}

# VERSION_ID を持たない rolling 系（major は空になる）。
test_os_without_version_id() {
  local f
  f=$(_write_os_release <<'EOF'
ID=arch
EOF
)
  booch_detect_os "$f"
  rm -f "$f"
  assert_eq "arch" "$BOOCH_OS_ID"
  assert_eq ""     "$BOOCH_OS_VERSION_ID"
  assert_eq ""     "$BOOCH_OS_VERSION_MAJOR"
  assert_eq ""     "$BOOCH_OS_CODENAME"
}

# ファイル不在なら全て空で、終了コードは 0（落ちない）。
test_os_missing_file_is_empty_and_ok() {
  local rc
  if booch_detect_os "/nonexistent/os-release"; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_eq "" "$BOOCH_OS_ID"
  assert_eq "" "$BOOCH_OS_VERSION_ID"
  assert_eq "" "$BOOCH_OS_VERSION_MAJOR"
  assert_eq "" "$BOOCH_OS_CODENAME"
}

# 直前の検出結果が次の呼び出しに残らない（毎回リセット）。
test_os_resets_between_calls() {
  local f
  f=$(_write_os_release <<'EOF'
ID=ubuntu
VERSION_ID="26.04"
VERSION_CODENAME=resolute
EOF
)
  booch_detect_os "$f"
  rm -f "$f"
  assert_eq "ubuntu" "$BOOCH_OS_ID"
  booch_detect_os "/nonexistent/os-release"
  assert_eq "" "$BOOCH_OS_ID"
  assert_eq "" "$BOOCH_OS_CODENAME"
  assert_eq "" "$BOOCH_OS_VERSION_MAJOR"
}

# caller が set -u でも、os-release がサブシェルを早期終了させる（exit を含む等）
# 内容でも、未初期化変数参照で caller を巻き込まず空で抜ける（rc 0）。
test_os_file_with_exit_does_not_crash_under_nounset() {
  set -u
  local f
  f=$(_write_os_release <<'EOF'
ID=ubuntu
exit 0
VERSION_ID="9.9"
EOF
)
  local rc
  if booch_detect_os "$f"; then rc=0; else rc=$?; fi
  rm -f "$f"
  assert_status 0 "$rc"
  assert_eq "" "$BOOCH_OS_VERSION_MAJOR"
  assert_eq "" "$BOOCH_OS_ID"
}

run_tests
