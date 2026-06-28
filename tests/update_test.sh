#!/usr/bin/env bash
# vendor/update.sh のユニットテスト。curl を shim で差し替えてネットワーク非依存にし、
# チェックサム検証とアトミック配置（失敗時に .tmp / 壊れた成果物を残さない）を確認する。
# リポジトリ本体の vendor/ は触らず、update.sh を temp にコピーして検証する。

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"

# update.sh を temp の「vendor」ディレクトリにコピーする（BC_DIR は update.sh の
# 位置基準で解決されるため、本体の vendor/bash-concurrent を汚さない）。
_make_env() {
  local d; d=$(mktemp -d)
  cp "$BOOCH_ROOT/vendor/update.sh" "$d/update.sh"
  mkdir -p "$d/bash-concurrent"
  printf '%s' "$d"
}

# -o の出力先と URL を見て、指定したファイルをコピーする curl shim を作る。
# $1=env dir, $2=concurrent.lib.sh として配るファイル
_make_curl_shim() {
  local bin="$1/bin"
  mkdir -p "$bin"
  cat > "$bin/curl" <<SHIM
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *)  url="\$1"; shift ;;
  esac
done
case "\$url" in
  *concurrent.lib.sh) cp "$2" "\$out" ;;
  *LICENSE)           printf 'TEST LICENSE\n' > "\$out" ;;
  *) echo "shim: unexpected url \$url" >&2; exit 22 ;;
esac
SHIM
  chmod +x "$bin/curl"
  printf '%s' "$bin"
}

# 正しい版（本物の lib）を配れば成功し、.tmp を残さず sha も一致する。冪等。
test_update_success_no_tmp_left() {
  local d bin rc
  d=$(_make_env)
  bin=$(_make_curl_shim "$d" "$BOOCH_ROOT/vendor/bash-concurrent/concurrent.lib.sh")
  if PATH="$bin:$PATH" bash "$d/update.sh" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
  assert_eq "" "$(find "$d/bash-concurrent" -name '*.tmp' -print -quit)" "no .tmp left"
  assert_eq "$(sha256sum "$BOOCH_ROOT/vendor/bash-concurrent/concurrent.lib.sh" | awk '{print $1}')" \
            "$(sha256sum "$d/bash-concurrent/concurrent.lib.sh" | awk '{print $1}')" "sha matches pin"
  rm -rf "$d"
}

# チェックサム不一致なら非 0 で失敗し、成果物を配置せず .tmp も残さない。
test_update_checksum_mismatch_fails_clean() {
  local d bin bad rc
  d=$(_make_env)
  bad=$(mktemp); printf 'garbage, not the real lib\n' > "$bad"
  bin=$(_make_curl_shim "$d" "$bad")
  if PATH="$bin:$PATH" bash "$d/update.sh" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
  assert_file_absent "$d/bash-concurrent/concurrent.lib.sh" "mismatch なら未配置"
  assert_eq "" "$(find "$d/bash-concurrent" -name '*.tmp' -print -quit)" "no .tmp left"
  rm -rf "$d" "$bad"
}

run_tests
