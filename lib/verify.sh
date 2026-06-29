#!/usr/bin/env bash
# 取得物（バイナリ / tarball / .deb）の SHA256 検証ヘルパー。
#
# 「最新版を入れる」ジョブは版が事前に未知で、固定 SHA256 ピン（vendor 方式）を置けない。
# 代わりに upstream が実行時に公開するチェックサム（go の `<file>.sha256` /
# GitHub Releases の `checksums.txt` 等）を引いて照合する。upstream がチェックサムを
# 出していないツール（delta / codex の単体バイナリ / aws）は検証不可（未検証）。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/verify.sh"
#   booch_verify_sha256 /path/file "$expected_hex"          # 純粋照合（network 不要）
#   want=$(booch_verify_pick "$asset" < checksums.txt)       # checksums.txt から拾う
#
# 依存: sha256sum（GNU coreutils）, curl。
#
# テスト用の継ぎ目（seam）。次を上書きすると network 無しで照合ロジックを検証できる:
#   booch_verify_fetch <url>   URL 本文を stdout へ（チェックサムファイル取得用）

booch_verify_fetch() { # url
  curl -fsSL --max-time 15 "$1"
}

# file の SHA256 が expected（64 桁 hex）と一致するか。純粋関数（network 不要）。
# 期待値が空・ハッシュ計算不能・不一致はいずれも非 0 で、差分を stderr に出す。
# 大文字小文字は無視する（upstream により hex の表記が揺れることがある）。
booch_verify_sha256() { # file expected
  local file=$1 expected=$2 got
  if [ -z "$expected" ]; then
    echo "verify: 期待ハッシュが空です: $file" >&2
    return 1
  fi
  got=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
  if [ -z "$got" ]; then
    echo "verify: ハッシュを計算できません: $file" >&2
    return 1
  fi
  if [ "${got,,}" != "${expected,,}" ]; then
    echo "verify: SHA256 不一致: $file" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $got" >&2
    return 1
  fi
}

# checksums.txt 形式（"<hash>  <filename>" の行集合）を stdin で受け、asset の期待
# ハッシュを stdout へ返す純粋関数。BSD 形式（"<hash> *<filename>"）の先頭 * と、CRLF
# 改行の末尾 CR を外して照合する。見つからなければ非 0（空出力）。
booch_verify_pick() { # asset   (checksums text on stdin)
  awk -v want="$1" '
    { name=$2; sub(/^\*/, "", name); sub(/\r$/, "", name); if (name == want) { print $1; found=1; exit } }
    END { exit !found }
  '
}
