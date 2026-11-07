#!/usr/bin/env bash
# booch bootstrap: 素の WSL2 / Ubuntu から booch を使う dotfiles を入れ、その setup を起動する。
# git すら無い状態から「dotfiles の setup が走る状態」までを 1 コマンドで持っていく。
# （Windows 版の素 OS bootstrap は別リポジトリ kan/booch-win の win.ps1 が担う。本ファイルは
#   その Linux/WSL2 版に当たる。）
#
# 使い方（ワンライナー）:
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/kan/booch/main/install.sh | bash
#   # 引数を渡す場合は bash -s -- で後続をスクリプトへ:
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/kan/booch/main/install.sh | bash -s -- \
#       --dir "$HOME/dotfiles" --repo youraccount/dotfiles
#
# 何をするか（各ステップ冪等。無ければ入れる / 既存なら更新）:
#   1. 前提ツール（git / curl / gh）を確保する（不足分のみ。apt は sudo を使う）。gh の keyring は
#      fingerprint を照合してから置く（照合用に gpg も入れる）
#   2. gh のブラウザ認証（private repo 取得のため。認証済みならスキップ）
#   3. dotfiles repo を --dir へ clone（既存なら ff-only pull）
#   4. submodule を初期化（submodule 方式で取り込んだ booch を取得）
#   5. booch が見つからなければ既定の sibling パスへ clone（--booch-ref に pin。既定は最新のリリースタグ）
#   6. dotfiles の setup（bootstrap.sh / setup/dotfiles を自動検出）へ委譲
#
# 対象: WSL2 / Ubuntu, GNU coreutils。テスト時は BOOCH_INSTALL_NO_RUN=1 で source すると
# main を実行せず関数定義だけ読み込める（tests/install_test.sh が利用）。
# 注意: クリーンに近い環境での実地スモークは未実施（curl|bash 下での gh auth の tty 取り回し等）。
set -uo pipefail

BOOCH_INSTALL_BOOCH_REPO="https://github.com/kan/booch"

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

# apt の index を更新する。apt-get update は一部の repo を取得できなくても 0 を返すので、
# APT::Update::Error-Mode=any で非 0 にする（この項目を知らない古い apt では無視される）。
# 素の OS からの bootstrap では、古い index のまま進むと後続の導入も失敗しやすいので止める
# （lib/apt.sh の booch_apt_update と違い、続行する選択肢は持たない）。
booch_install_apt_update() {
  booch_install_apt update -qq -o APT::Update::Error-Mode=any \
    || _bi_err "apt update に失敗（取得できなかった repo がある場合も含む）"
}

# 1. 前提ツール。git / curl は universe、gh は github-cli の apt repo を足してから入れる。
# gpg は gh の keyring の照合に使う（Ubuntu では optional で、素のイメージには無いことがある）。
booch_install_prereqs() {
  if _bi_have git && _bi_have curl && _bi_have gh; then
    _bi_ok "git / curl / gh あり"; return 0
  fi
  _bi_step "前提ツールを確保する"
  local base=()
  _bi_have git  || base+=(git)
  _bi_have curl || base+=(curl)
  _bi_have gh || _bi_have gpg || base+=(gpg)
  if [ "${#base[@]}" -gt 0 ]; then
    booch_install_apt_update || return 1
    booch_install_apt install -y "${base[@]}" || { _bi_err "前提ツールの導入に失敗: ${base[*]}"; return 1; }
  fi
  if ! _bi_have gh; then
    booch_install_ensure_gh_repo || return 1
    booch_install_apt_update || return 1
    booch_install_apt install -y gh || { _bi_err "gh の導入に失敗"; return 1; }
  fi
  _bi_ok "git / curl / gh 用意"
}

# gh の apt リポジトリに署名する鍵の主鍵の fingerprint。上流が公開している値
# （https://github.com/cli/cli/blob/trunk/docs/install_linux.md の冒頭）と同じにする。
# 上流が鍵を足したり替えたりしたら、ここを直す。.github/workflows/gh-keyring.yml が週 1 回、
# 上流の keyring をこの値で照合するので、ずれれば赤で気付く。
_BI_GH_KEY_FPRS=(
  2C6106201985B60E6C7AC87323F3D4EA75716059
  7F38BBB59D064DBCB3D84D725612B36462313325
)

# keyring の鍵レコードを gpg のコロン形式で返す（seam）。--show-keys は import しないが、
# 利用者の ~/.gnupg を作ったり触ったりしないよう、使い捨ての GNUPGHOME で読む。
booch_install_gh_key_records() { # keyring
  local home rc=0
  home=$(mktemp -d) || return 1
  GNUPGHOME="$home" gpg --batch --show-keys --with-colons "$1" 2>/dev/null || rc=$?
  rm -rf "$home"
  return "$rc"
}

# keyring の主鍵が 1 本以上あり、すべて _BI_GH_KEY_FPRS に含まれるかを確かめる。
# 「固定した鍵を 1 本でも含めば通す」にすると、鍵を足された keyring も通ってしまう
# （apt は keyring の鍵をすべて信用する）ので、1 本でも外れていれば落とす。
# lib/apt.sh の booch_apt_verify_keyring が同じ規則で照合している（install.sh は自己完結の
# ため共有できない）。規則を変えるときは両方を直す。
booch_install_verify_gh_keyring() { # keyring
  local records fprs fpr pinned
  # gpg が一部の鍵を読めずに非 0 で終えたときも通さない（読めなかった鍵を照合できないため）。
  records=$(booch_install_gh_key_records "$1") \
    || { _bi_err "gh keyring を gpg で読めない（gpg が古い、または読めない鍵が入っている）"; return 1; }
  # fpr 行は pub の直後が主鍵、sub の直後が副鍵。主鍵だけを取り出す。
  fprs=$(printf '%s\n' "$records" | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10 } { p = 0 }')
  [ -n "$fprs" ] || { _bi_err "gh keyring に鍵が無い"; return 1; }
  # fingerprint は空白を含まない 16 進なので、空白で区切った一覧への一致で集合に含まれるかを見られる。
  # 一覧は printf で組む（"${arr[*]}" は IFS の先頭文字で区切るので、呼び出し側の IFS に左右される）。
  pinned=" $(printf '%s ' "${_BI_GH_KEY_FPRS[@]}")"
  while IFS= read -r fpr; do
    case "$pinned" in
      *" $fpr "*) ;;
      *) _bi_err "gh keyring に想定外の鍵がある: $fpr"; return 1 ;;
    esac
  done <<<"$fprs"
}

# gh の keyring を取得する（seam）。
# --proto '=https' --tlsv1.2: リダイレクトで平文の http へ落ちることと、TLS の格下げを拒否する。
booch_install_fetch_gh_keyring() { # out-file
  curl --proto '=https' --tlsv1.2 -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$1"
}

# gh の apt リポジトリの keyring と deb 行の置き場所（テストで差し替える）。
_BI_GH_KEYRING=/etc/apt/keyrings/githubcli-archive-keyring.gpg
_BI_GH_LIST=/etc/apt/sources.list.d/github-cli.list

# keyring を一時ファイル <tmp> へ取って照合し、通ったものだけを _BI_GH_KEYRING に置く。
_bi_place_gh_keyring() { # tmp
  booch_install_fetch_gh_keyring "$1" || { _bi_err "gh keyring の取得に失敗"; return 1; }
  booch_install_verify_gh_keyring "$1" \
    || { _bi_err "gh keyring の fingerprint が install.sh の固定値と一致しない。keyring を置かずに中断する"; return 1; }
  local dir; dir=$(dirname "$_BI_GH_KEYRING")
  sudo install -m 0755 -d "$dir" || { _bi_err "$dir の作成に失敗"; return 1; }
  # apt は root 以外からも読むので 0644 で置く。
  sudo install -m 0644 "$1" "$_BI_GH_KEYRING" || { _bi_err "gh keyring の配置に失敗"; return 1; }
}

# gh の公式 apt リポジトリを冪等に足す（keyring + deb 行）。booch 本体を使わず自己完結する。
# 既に両方あれば何もしない（既存の keyring は照合しない）。
booch_install_ensure_gh_repo() {
  [ -f "$_BI_GH_LIST" ] && [ -r "$_BI_GH_KEYRING" ] && return 0
  _bi_step "github-cli の apt リポジトリを追加する"
  local tmp rc=0
  tmp=$(mktemp) || return 1
  _bi_place_gh_keyring "$tmp" || rc=1
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || return 1
  local arch; arch=$(dpkg --print-architecture)
  printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' "$arch" "$_BI_GH_KEYRING" \
    | sudo tee "$_BI_GH_LIST" >/dev/null || return 1
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
booch_install_ensure_booch() { # dir [ref]
  local dir=$1 ref=${2:-} sib
  booch_install_git -C "$dir" submodule update --init --recursive 2>/dev/null || true
  if [ -f "$dir/vendor/booch/lib/runner.sh" ]; then
    _bi_ok "booch: submodule (vendor/booch)"; return 0
  fi
  sib="$(dirname "$dir")/booch"
  if [ -f "$sib/lib/runner.sh" ]; then
    _bi_ok "booch: $sib"; return 0
  fi
  _bi_step "booch を clone: $sib"
  booch_install_git clone "$BOOCH_INSTALL_BOOCH_REPO" "$sib" || { _bi_err "booch の clone に失敗"; return 1; }
  # ref 未指定なら clone 済みのタグから最新のリリースを選ぶ（版番号を install.sh に持たない）。
  if [ -z "$ref" ]; then
    ref=$(booch_install_git -C "$sib" tag --list 'v*' --sort=-v:refname | head -n1)
    [ -n "$ref" ] || { _bi_warn "リリースタグが見つからない（既定ブランチのまま）"; return 0; }
  fi
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
  --booch-ref <tag>   sibling clone 時の booch タグ（既定: 最新のリリースタグ）
  --run <relpath>     setup エントリを明示（既定: bootstrap.sh / setup/dotfiles を自動検出）
USAGE
}

booch_install_main() {
  local dir="$HOME/dotfiles" repo="${BOOCH_INSTALL_REPO:-}" ref="" run=""
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
# 処理はすべて関数に閉じ、ここで初めて起動する。curl|bash でダウンロードが途中で切れても、
# この if より前で切れれば何も実行されず、if の中で切れれば構文エラーで実行されない
# （途中までのスクリプトが半端に動かない）。起動をこの末尾の 1 箇所に保つこと。
if [ "${BOOCH_INSTALL_NO_RUN:-0}" != 1 ]; then
  booch_install_main "$@"
fi
