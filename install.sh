#!/usr/bin/env bash
# booch bootstrap: 素の WSL2 / Ubuntu から booch を使う dotfiles を入れ、その setup を起動する。
# git すら無い状態から「dotfiles の setup が走る状態」までを 1 コマンドで持っていく。
# （Windows 版の素 OS bootstrap は別リポジトリ kan/booch-win の win.ps1 が担う。本ファイルは
#   その Linux/WSL2 版に当たる。）
#
# 使い方（ワンライナー）:
#   curl -fsSL https://raw.githubusercontent.com/kan/booch/v1.0.0/install.sh | bash
#   # 引数を渡す場合は bash -s -- で後続をスクリプトへ:
#   curl -fsSL https://raw.githubusercontent.com/kan/booch/v1.0.0/install.sh | bash -s -- \
#       --dir "$HOME/dotfiles" --repo youraccount/dotfiles
#
# 何をするか（各ステップ冪等。無ければ入れる / 既存なら更新）:
#   1. 前提ツール（git / curl / gh）を確保する（不足分のみ。apt は sudo を使う）
#   2. gh のブラウザ認証（private repo 取得のため。認証済みならスキップ）
#   3. dotfiles repo を --dir へ clone（既存なら ff-only pull）
#   4. submodule を初期化（submodule 方式で取り込んだ booch を取得）
#   5. booch が見つからなければ既定の sibling パスへ clone（--booch-ref に pin）
#   6. dotfiles の setup（bootstrap.sh / setup/dotfiles を自動検出）へ委譲
#
# 対象: WSL2 / Ubuntu, GNU coreutils。テスト時は BOOCH_INSTALL_NO_RUN=1 で source すると
# main を実行せず関数定義だけ読み込める（tests/install_test.sh が利用）。
# 注意: クリーンに近い環境での実地スモークは未実施（curl|bash 下での gh auth の tty 取り回し等）。
set -uo pipefail

BOOCH_INSTALL_BOOCH_REPO="https://github.com/kan/booch"
BOOCH_INSTALL_BOOCH_REF_DEFAULT="v1.0.0"

# 色は tty かつ NO_COLOR 未設定のときだけ（パイプ/CI にエスケープを混ぜない）。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _BI_C=$'\033[36m'; _BI_G=$'\033[32m'; _BI_Y=$'\033[33m'; _BI_R=$'\033[0m'
else
  _BI_C=''; _BI_G=''; _BI_Y=''; _BI_R=''
fi
_bi_step() { printf '%s==>%s %s\n' "$_BI_C" "$_BI_R" "$*"; }
_bi_ok()   { printf '  %s[OK]%s %s\n' "$_BI_G" "$_BI_R" "$*"; }
_bi_warn() { printf '  %s[!]%s %s\n'  "$_BI_Y" "$_BI_R" "$*" >&2; }
_bi_err()  { printf '  %s[x]%s %s\n'  "$_BI_Y" "$_BI_R" "$*" >&2; return 1; }
_bi_have() { command -v "$1" >/dev/null 2>&1; }

# 副作用の継ぎ目（seam）。テストで上書きして network / sudo / 実行なしに検証する。
booch_install_apt()  { sudo apt-get "$@"; }
booch_install_gh()   { gh "$@"; }
booch_install_git()  { git "$@"; }
booch_install_exec() { ( cd "$1" && bash "$2" ); }   # dotfiles setup の実行

# 1. 前提ツール。git / curl は universe、gh は github-cli の apt repo を足してから入れる。
booch_install_prereqs() {
  if _bi_have git && _bi_have curl && _bi_have gh; then
    _bi_ok "git / curl / gh あり"; return 0
  fi
  _bi_step "前提ツールを確保する"
  local base=()
  _bi_have git  || base+=(git)
  _bi_have curl || base+=(curl)
  if [ "${#base[@]}" -gt 0 ]; then
    booch_install_apt update -qq || { _bi_err "apt update に失敗"; return 1; }
    booch_install_apt install -y "${base[@]}" || { _bi_err "前提ツールの導入に失敗: ${base[*]}"; return 1; }
  fi
  if ! _bi_have gh; then
    booch_install_ensure_gh_repo || return 1
    booch_install_apt update -qq || { _bi_err "apt update に失敗"; return 1; }
    booch_install_apt install -y gh || { _bi_err "gh の導入に失敗"; return 1; }
  fi
  _bi_ok "git / curl / gh 用意"
}

# gh の公式 apt リポジトリを冪等に足す（keyring + deb 行）。booch 本体を使わず自己完結する。
booch_install_ensure_gh_repo() {
  local kr=/etc/apt/keyrings/githubcli-archive-keyring.gpg
  local list=/etc/apt/sources.list.d/github-cli.list
  [ -f "$list" ] && [ -r "$kr" ] && return 0
  _bi_step "github-cli の apt リポジトリを追加する"
  sudo install -m 0755 -d /etc/apt/keyrings || return 1
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee "$kr" >/dev/null || { _bi_err "gh keyring の取得に失敗"; return 1; }
  sudo chmod go+r "$kr" || return 1
  local arch; arch=$(dpkg --print-architecture)
  printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' "$arch" "$kr" \
    | sudo tee "$list" >/dev/null || return 1
}

# 2. gh 認証（未認証なら対話ログイン）。
booch_install_auth() {
  if booch_install_gh auth status >/dev/null 2>&1; then
    _bi_ok "gh 認証済み"; return 0
  fi
  _bi_step "gh にログインする（private repo 取得のため）"
  booch_install_gh auth login || { _bi_err "gh ログインに失敗"; return 1; }
}

# 3. dotfiles を clone（既存なら ff-only pull）。
booch_install_clone() { # repo dir
  local repo=$1 dir=$2
  if [ -d "$dir/.git" ]; then
    _bi_step "dotfiles を更新: $dir"
    booch_install_git -C "$dir" pull --ff-only || _bi_warn "pull に失敗（続行）"
  else
    _bi_step "dotfiles を clone: $repo -> $dir"
    booch_install_gh repo clone "$repo" "$dir" || { _bi_err "clone に失敗: $repo"; return 1; }
  fi
}

# 4+5. booch を確保。submodule を初期化し、無ければ sibling へ clone（ref に pin）。
booch_install_ensure_booch() { # dir ref
  local dir=$1 ref=$2 sib
  booch_install_git -C "$dir" submodule update --init --recursive 2>/dev/null || true
  if [ -f "$dir/vendor/booch/lib/runner.sh" ]; then
    _bi_ok "booch: submodule (vendor/booch)"; return 0
  fi
  sib="$(dirname "$dir")/booch"
  if [ -f "$sib/lib/runner.sh" ]; then
    _bi_ok "booch: $sib"; return 0
  fi
  _bi_step "booch を clone: $sib ($ref)"
  booch_install_git clone "$BOOCH_INSTALL_BOOCH_REPO" "$sib" || { _bi_err "booch の clone に失敗"; return 1; }
  booch_install_git -C "$sib" checkout "$ref" || _bi_warn "タグ $ref への checkout に失敗（既定ブランチのまま）"
}

# 6. dotfiles の setup へ委譲（bootstrap.sh / setup/dotfiles を自動検出。override で明示可）。
booch_install_run() { # dir [override]
  local dir=$1 override=${2:-} entry=""
  if [ -n "$override" ]; then entry=$override
  elif [ -f "$dir/bootstrap.sh" ]; then entry="bootstrap.sh"
  elif [ -f "$dir/setup/dotfiles" ]; then entry="setup/dotfiles"
  fi
  if [ -z "$entry" ]; then
    _bi_warn "setup エントリが見つかりません。$dir で手動セットアップしてください"
    return 0
  fi
  _bi_step "dotfiles の setup を起動: $entry"
  booch_install_exec "$dir" "$entry"
}

_bi_usage() {
  cat <<'USAGE'
booch bootstrap — 素の WSL2/Ubuntu から booch を使う dotfiles を入れる
  --dir <path>        dotfiles の配置先（既定: ~/dotfiles）
  --repo <owner/name> 取り込む dotfiles repo（必須。環境変数 BOOCH_INSTALL_REPO でも指定可）
  --booch-ref <tag>   sibling clone 時の booch タグ（既定: v1.0.0）
  --run <relpath>     setup エントリを明示（既定: bootstrap.sh / setup/dotfiles を自動検出）
USAGE
}

booch_install_main() {
  local dir="$HOME/dotfiles" repo="${BOOCH_INSTALL_REPO:-}" ref="$BOOCH_INSTALL_BOOCH_REF_DEFAULT" run=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)       dir=${2:-}; shift 2 ;;
      --repo)      repo=${2:-}; shift 2 ;;
      --booch-ref) ref=${2:-}; shift 2 ;;
      --run)       run=${2:-}; shift 2 ;;
      -h | --help) _bi_usage; return 0 ;;
      *) _bi_err "不明な引数: $1"; _bi_usage >&2; return 1 ;;
    esac
  done
  # 汎用ツールなので取り込む dotfiles repo を既定に埋め込まない。--repo か
  # 環境変数 BOOCH_INSTALL_REPO で受け、未指定なら副作用の前に中断する。
  if [ -z "$repo" ]; then
    _bi_err "取り込む dotfiles repo が未指定です。--repo <owner>/<name> か環境変数 BOOCH_INSTALL_REPO を指定してください。"
    _bi_usage >&2
    return 1
  fi
  booch_install_prereqs || return 1
  booch_install_auth || return 1
  booch_install_clone "$repo" "$dir" || return 1
  booch_install_ensure_booch "$dir" "$ref" || return 1
  booch_install_run "$dir" "$run" || return 1
  _bi_ok "完了: $dir"
}

# curl|bash / 直接実行では main を走らせる。テストは BOOCH_INSTALL_NO_RUN=1 で source する。
if [ "${BOOCH_INSTALL_NO_RUN:-0}" != 1 ]; then
  booch_install_main "$@"
fi
