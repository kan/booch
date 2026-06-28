#!/usr/bin/env bash
# git の汎用ユーティリティ。複数リポジトリの安全な ff-only pull と、スクリプト自身が
# 置かれたリポジトリの自己更新（pull 後に再 exec）。どのリポジトリを対象にするか・許可
# ブランチ・確認するか等の方針は利用側が決める。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/git.sh"
#   booch_git_self_update "$DOTFILES_DIR" "$DOTFILES_DIR/setup/dotfiles" "$@"
#   booch_git_pull_repos "$HOME" master,main,develop cl-core biz-core ...
#
# 依存: git, awk, timeout。色は lib/color.sh（runner 等が source 済みの前提。未定義でも
# 空文字で動く）。
#
# テスト用の継ぎ目（seam）:
#   booch_git_self_update_confirm   pull する y/N（tty が無ければ no）
#   booch_git_reexec <cmd...>       pull 後の再実行（exec）

# 色が未定義（color.sh 未 source）でも set -u を巻き込まないよう空で用意する。
: "${_BOOCH_COLOR_RED:=}" "${_BOOCH_COLOR_YELLOW:=}" "${_BOOCH_COLOR_GREEN:=}" "${_BOOCH_COLOR_RESET:=}"

# 単一リポジトリを fast-forward のみで pull する。許可ブランチ（CSV、既定
# master,main,develop）上で、かつ未コミット差分が無いときだけ。状態を 1 行で表示する。
# 保守処理なので個別の失敗で全体を止めず常に 0 を返す。ラベル（リポジトリ名等）は
# 呼び出し側が前置きする想定（本関数は状態文字列のみを出力する）。
booch_git_pull_ff_clean() { # repo_dir [branches_csv]
  local dir=$1 branches=${2:-master,main,develop}
  if [ ! -d "$dir/.git" ]; then
    echo "(not a git repo: $dir)"
    return 0
  fi
  local branch; branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  case ",$branches," in
    *",$branch,"*) ;;
    *) printf '[SKIP] branch %s (allowed: %s)\n' "${branch:-unknown}" "$branches"; return 0 ;;
  esac
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    printf '%s[WARN]%s local changes, skip pull (%s)\n' \
      "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET" "$branch"
    return 0
  fi
  local out
  if out=$(git -C "$dir" pull --ff-only 2>&1); then
    if printf '%s' "$out" | grep -q "Already up to date"; then
      printf '%s=%s up to date (%s)\n' "$_BOOCH_COLOR_GREEN" "$_BOOCH_COLOR_RESET" "$branch"
    else
      printf '%s^%s updated (%s)\n' "$_BOOCH_COLOR_GREEN" "$_BOOCH_COLOR_RESET" "$branch"
    fi
  else
    printf '%s[WARN]%s pull failed (%s): %s\n' \
      "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET" "$branch" "$(printf '%s' "$out" | tail -1)"
  fi
  return 0
}

# base_dir 配下の複数リポジトリ（名前で指定）を ff-only pull する。各リポジトリ名を
# 左詰めで表示してから booch_git_pull_ff_clean を適用する。
booch_git_pull_repos() { # base_dir branches_csv repo...
  local base=$1 branches=$2; shift 2
  local repo found=false
  for repo in "$@"; do
    [ -d "$base/$repo/.git" ] || continue
    found=true
    printf '  %-18s' "$repo"
    booch_git_pull_ff_clean "$base/$repo" "$branches"
  done
  $found || echo "  (no target repositories found)"
}

# pull する y/N（seam）。tty が無ければ no（非対話では更新しない）。
booch_git_self_update_confirm() {
  local ans=""
  if { true >/dev/tty; } 2>/dev/null; then
    read -rp "git pull? [y/N] " -n 1 ans </dev/tty
    echo
  fi
  [[ $ans =~ ^[Yy]$ ]]
}

# pull 後の再実行（seam）。本番は exec で現プロセスを置き換える。
booch_git_reexec() { exec "$@"; }

# repo_dir のリポジトリを自己更新する。リモートに更新があれば確認のうえ pull し、与えた
# コマンドで再実行する。fetch 失敗は「最新」と誤判定しないよう exit 1 で中断する。
#   booch_git_self_update <repo_dir> <reexec_cmd...>
booch_git_self_update() {
  local dir=$1; shift
  [ -d "$dir/.git" ] || return 0
  echo "Checking for updates in $dir..."
  local fetch_err fetch_status
  fetch_err=$(timeout 10 git -C "$dir" fetch --quiet 2>&1)
  fetch_status=$?
  if [ "$fetch_status" -ne 0 ]; then
    printf '%sError:%s failed to fetch; aborting.\n' "$_BOOCH_COLOR_RED" "$_BOOCH_COLOR_RESET" >&2
    [ -n "$fetch_err" ] && echo "  git fetch: $fetch_err" >&2
    exit 1
  fi
  local counts ahead behind
  counts=$(git -C "$dir" rev-list --left-right --count "HEAD...@{u}" 2>/dev/null || echo "0 0")
  ahead=$(echo "$counts" | awk '{print $1}')
  behind=$(echo "$counts" | awk '{print $2}')
  if [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
    echo "Diverged: local ahead ${ahead}, remote ahead ${behind}. Resolve manually (rebase/merge)."
  elif [ "$behind" -gt 0 ]; then
    echo "${behind} update(s) available."
    if booch_git_self_update_confirm; then
      git -C "$dir" pull
      echo "Re-running the latest version..."
      booch_git_reexec "$@"
    fi
  elif [ "$ahead" -gt 0 ]; then
    echo "Local is ahead by ${ahead}."
  else
    echo "Up to date."
  fi
}
