#!/usr/bin/env bash
# lib/ の補助ヘルパーの使い方を示す小品（fs.sh / confirm.sh / sudo.sh）。副作用が安全な
# ものは一時ディレクトリで実際に動かし、sudo の事前キャッシュは雛形の提示にとどめる。
#
# 実行: bash examples/lib-helpers.sh
set -uo pipefail

BOOCH_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export BOOCH_ROOT
source "$BOOCH_ROOT/lib/fs.sh"
source "$BOOCH_ROOT/lib/confirm.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== fs.sh: symlink を冪等に配置 =="
# 本来は dotfiles の実体 → $HOME 配下の設定パスを張る用途。ここでは temp で示す。
printf 'set -o vi\n' > "$tmp/bashrc.real"
booch_symlink "$tmp/bashrc.real" "$tmp/.bashrc"
booch_symlink "$tmp/bashrc.real" "$tmp/.bashrc"   # 2 回目は「symlink 済み」（冪等）

echo
echo "== fs.sh: TOML のキーを冪等に更新（他キーは保たれる） =="
booch_set_toml_key "$tmp/config.toml" model '"gpt-5.4"'
booch_set_toml_key "$tmp/config.toml" model '"o3"'          # 既存キーは値を置換
booch_set_toml_key "$tmp/config.toml" approval '"on-request"'
cat "$tmp/config.toml"

echo
echo "== confirm.sh: 「更新があるときだけ確認」をジョブ登録の前に判断 =="
# 未導入（CURRENT 空）は確認なしで 0。ここでは ASSUME_YES=true で非対話に通す例を示す。
if booch_confirm_update "Example" "1.0.0" "1.1.0" true; then
  echo "→ 進める（booch_job ... を登録して更新する）"
else
  echo "→ 見送り（現状維持）"
fi

echo
cat <<'NOTE'
== sudo.sh: 並列実行前に認証を 1 回だけキャッシュ ==
多くのジョブが sudo を使う場合、booch_run の前に認証をキャッシュしておくと、各ジョブの
sudo がプロンプト無しで通る（このサンプルでは実際には実行しない）:

  source "$BOOCH_ROOT/lib/sudo.sh"
  booch_sudo_prime || exit 1     # 対話で 1 回だけ認証 + キープアライブ開始
  trap 'booch_sudo_stop' EXIT
  booch_run
NOTE
