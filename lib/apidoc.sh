#!/usr/bin/env bash
# apidoc: lib/*.sh・jobs/*.sh の「冒頭ヘッダコメント」と「公開関数シグネチャ」を抽出し、
# `booch help [name]` 用のモジュール索引・詳細を組み立てる。API の正本は各ファイルの
# 冒頭コメントと `booch_xxx() { # args` 宣言なので、本ヘルパーはそれを読み出して整形する
# だけで、説明を二重管理しない（正本＝ソース。CLAUDE.md「header＝個別 API の正本」に沿う）。
# 将来 docs/API.md を生成する場合も、この抽出関数を再利用する。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/apidoc.sh"
#   booch_apidoc_index                 # 全モジュールの一覧（kind + name + 1 行説明）
#   booch_apidoc_show fs               # fs.sh のヘッダ全文 + 公開関数シグネチャ
#
# 抽出規約:
#   - ヘッダ: 1 行目の shebang を飛ばし、以降の連続する `#` 行を「# 」を外して取る
#     （最初の非コメント行で打ち切り）。ファイル冒頭コメントブロックがそのまま該当する。
#   - 1 行説明: ヘッダの最初の非空行。
#   - 公開関数: 行頭が `booch_*() {` または `job_*() {`。内部関数（`_booch_*`）は出さない。
#     宣言末尾の `# args` ヒントがあれば併記する。
#
# seam: モジュールの探索は BOOCH_ROOT/lib・BOOCH_ROOT/jobs を対象にする。

# BOOCH_ROOT 未設定時（単体 source / テスト）は本ファイルから推定する。
if [ -z "${BOOCH_ROOT:-}" ]; then
  BOOCH_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd) || BOOCH_ROOT=""
fi

# ファイル冒頭のヘッダコメントブロックを「# 」を外して出力する。
booch_apidoc_header() { # file
  awk '
    NR==1 && /^#!/ { next }        # shebang は飛ばす
    /^#/           { sub(/^#[ ]?/, ""); print; next }
    { exit }                       # 最初の非コメント行で終わり
  ' "$1"
}

# ヘッダの最初の非空行（1 行説明）を出力する。
booch_apidoc_summary() { # file
  booch_apidoc_header "$1" | awk 'NF { print; exit }'
}

# 公開関数のシグネチャを 1 行ずつ出力する（`name(args)` 形式）。
booch_apidoc_functions() { # file
  grep -E '^(booch_[a-z0-9_]+|job_[a-z0-9_]+)\(\) \{' "$1" 2>/dev/null \
    | sed -E \
        -e 's/\(\) \{ #[[:space:]]*(.*)$/(\1)/' \
        -e 's/\(\) \{.*/()/'
}

# name（拡張子なし）を lib → jobs の順で解決してファイルパスを出す（無ければ非 0）。
booch_apidoc_resolve() { # name
  local name=$1 cand
  for cand in "$BOOCH_ROOT/lib/$name.sh" "$BOOCH_ROOT/jobs/$name.sh"; do
    if [ -f "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# 全モジュール（lib → jobs）を "kind<TAB>name<TAB>path" で列挙する。
booch_apidoc_modules() {
  local kind f
  for kind in lib jobs; do
    for f in "$BOOCH_ROOT/$kind"/*.sh; do
      [ -e "$f" ] || continue
      printf '%s\t%s\t%s\n' "$kind" "$(basename "$f" .sh)" "$f"
    done
  done
}

# モジュール索引（kind ごとに name + 1 行説明）を出力する。
booch_apidoc_index() {
  printf 'モジュール一覧（詳細は booch help <name>）:\n'
  local prev_kind="" kind name path label
  while IFS=$'\t' read -r kind name path; do
    if [ "$kind" != "$prev_kind" ]; then
      case "$kind" in
        lib)  printf '\nライブラリ (lib/):\n' ;;
        jobs) printf '\n提供ジョブ (jobs/):\n' ;;
        *)    printf '\n%s:\n' "$kind" ;;
      esac
      prev_kind=$kind
    fi
    label=$(booch_apidoc_summary "$path")
    printf '  %-12s %s\n' "$name" "$label"
  done < <(booch_apidoc_modules)
}

# 1 モジュールの詳細（ヘッダ全文 + 公開関数シグネチャ）を出力する。
booch_apidoc_show() { # name
  local name=${1:-} file
  if [ -z "$name" ]; then
    booch_apidoc_index
    return 0
  fi
  if ! file=$(booch_apidoc_resolve "$name"); then
    printf 'booch help: 不明なモジュール: %s\n' "$name" >&2
    printf '  booch help で一覧を表示\n' >&2
    return 1
  fi
  printf '== %s (%s) ==\n\n' "$name" "${file#"$BOOCH_ROOT"/}"
  booch_apidoc_header "$file"
  local fns; fns=$(booch_apidoc_functions "$file")
  if [ -n "$fns" ]; then
    printf '\n公開関数:\n'
    printf '%s\n' "$fns" | sed 's/^/  /'
  fi
}
