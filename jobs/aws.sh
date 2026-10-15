#!/usr/bin/env bash
# booch 提供ジョブ: AWS CLI v2 と Session Manager Plugin の導入 / 更新（非対話）。
#
# AWS CLI は公式の awscli-exe zip（self-contained installer）、SSM プラグインは公式 .deb
# を使う。どちらも x86_64 / aarch64 に対応する。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/arch.sh"
#   source "$BOOCH_ROOT/jobs/aws.sh"
#   booch_job aws "AWS CLI + SSM Plugin" job_aws 180
#
# **AWS CLI の古い版は job_aws では消さない。** 公式インストーラの `install --update` は前の版の
# ディレクトリ（$BOOCH_AWS_CLI_ROOT、既定 /usr/local/aws-cli/v2 の下。1 版 約 270MB）を残す。
# 初回の削除が大きくジョブのタイムアウトに掛かりうるので、利用側が cleanup の段で呼ぶ:
#   booch_aws_cli_prune                          # current 以外の使われていない版を消す（sudo）
#   booch_aws_cli_stale_versions | wc -l         # doctor 等で残数を出す（表示だけなら sudo 無し。
#                                                # root のプロセスが使う版も数えるので多めに出ることがある）
#
# 依存: lib/arch.sh, curl, unzip, dpkg, sudo。古い版の判定は find（/proc の走査）と awk。
#
# テスト用の継ぎ目（seam）:
#   booch_aws_arch                       uname → x86_64 / aarch64
#   booch_aws_cli_installed_version      現在の aws-cli 版（未導入なら空）
#   booch_aws_cli_latest                 最新 aws-cli 版（公式 CHANGELOG）
#   booch_aws_cli_install <arch>         AWS CLI の導入（副作用）
#   booch_aws_ssm_installed_version      現在の SSM plugin 版（未導入なら空）
#   booch_aws_ssm_latest                 最新 SSM plugin 版（公式 /latest/VERSION）
#   booch_aws_ssm_install <arch>         SSM plugin の導入（副作用）
#   booch_aws_cli_root                   AWS CLI v2 の導入先（$BOOCH_AWS_CLI_ROOT で上書き）
#   booch_aws_proc_exes [sudo]           実行中プロセスの実行ファイルのパス（使用中の版の判定）

# AWS の配布アーキ名（x86_64 / aarch64）。lib/arch.sh の rust 系ラッパー。
booch_aws_arch() { booch_arch_rust_style; }

# --- AWS CLI v2 ---
booch_aws_cli_installed_version() {
  command -v aws >/dev/null 2>&1 || return 0
  aws --version 2>/dev/null | awk '{print $1}' | sed 's|aws-cli/||'
}

booch_aws_cli_latest() {
  # curl をパイプにすると失敗が awk の成功で隠れる。変数に捕捉して curl 失敗は return 1。
  local out
  out=$(curl -fsSL --max-time 15 https://raw.githubusercontent.com/aws/aws-cli/v2/CHANGELOG.rst 2>/dev/null) || return 1
  # 第 1 フィールドだけを取る。installed 側（aws --version の awk $1）と解析を対称にし、
  # 行末に注記/空白/CR が付いても版比較がズレない（毎回再導入ループを防ぐ）。
  printf '%s\n' "$out" | awk '/^[0-9]+\.[0-9]+\.[0-9]+/{print $1; exit}'
}

booch_aws_cli_install() { # arch
  local arch=$1
  local tmp; tmp=$(mktemp -d)
  # 発火時に自身を解除し、RETURN トラップが呼び出し元へ漏れて再発火するのを防ぐ
  # （呼び出し元の set -u 下で解放済みローカル変数を踏んで落ちないように）。
  trap 'rm -rf "${tmp:-}"; trap - RETURN' RETURN
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp/awscli.zip" || return 1
  unzip -q "$tmp/awscli.zip" -d "$tmp" || return 1
  sudo "$tmp/aws/install" --update
}

# --- AWS CLI v2 の古い版（ジョブではなく利用側の cleanup から消す） ---

# 公式インストーラの導入先（`install` の --install-dir の既定 /usr/local/aws-cli の下）。
booch_aws_cli_root() {
  printf '%s' "${BOOCH_AWS_CLI_ROOT:-/usr/local/aws-cli/v2}"
}

# 実行中のプロセスの実行ファイルのパスを 1 行ずつ出す（seam）。sudo を渡すと root のプロセスも
# 読める。readlink へ /proc/*/exe を並べて渡さない ―― uutils 版（Ubuntu 26.04）は読めない
# プロセスが 1 つあると何も出力せず、使用中の版を全部見落とす。find も読めないプロセスがあると
# 非 0 で終わるが、読めた分は出すので終了コードは捨てる（set -e の下で候補の算出が止まらないように）。
booch_aws_proc_exes() { # [sudo]
  ${1:+"$1"} find /proc -maxdepth 2 -name exe -printf '%l\n' 2>/dev/null || true
}

# 削除してよい版（current 以外）のディレクトリを 1 行ずつ出す（削除はしない）。新旧は見ないので、
# current を古い版へ戻したときは新しい版も候補になる。
#
# `install --update` は新しい版を <root>/<版>/ へ展開して current の symlink を張り替えるだけで、
# 前の版を消さない（1 版 約 270MB）。**current が指す版が自分の版を名乗るときだけ候補を出す。**
# 壊れた導入の上で古い版を消すと、動く aws が 1 つも残らなくなるため。
#
# 候補は root 直下の「名前が x.y.z の実ディレクトリ」だけ（symlink と他の名前には触らない）。
# 実行中のプロセスが使っている版も外す（別端末で開いたままの `aws ssm start-session` などが、
# 更新前の版のディレクトリからモジュールを読み続けているため）。sudo を渡すと root のプロセスが
# 使っている版も外せる。渡さなければ自分のプロセスしか見えないので、**削除する側は必ず sudo を渡す**
# （doctor のような表示だけの用途は sudo 無しでよいが、root のプロセスが使う版も数えるので多めに出る）。
# /proc を 1 行も読めない（sudo の失敗など）ときは、使用中の版を判定できないので候補を出さずに 1 を返す。
booch_aws_cli_stale_versions() { # [sudo]
  local root keep name d exes dirs=() stale=()
  local ver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
  root=$(booch_aws_cli_root)
  [ -L "$root/current" ] || return 0
  root=$(readlink -f "$root") || return 0
  keep=$(readlink -f "$root/current") || return 0
  name=${keep##*/}
  [ "$keep" = "$root/$name" ] || return 0
  [[ $name =~ $ver_re ]] || return 0

  for d in "$root"/*; do
    [[ ${d##*/} =~ $ver_re ]] || continue
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [ "$d" != "$keep" ] || continue
    dirs+=("$d")
  done
  # 古い版が無い（通常の状態）なら、/proc の走査と aws の起動をせずに終える。
  [ "${#dirs[@]}" -gt 0 ] || return 0
  # sudo の要る /proc の走査より先に、sudo 無しで済む current の確認をする。
  [ "$("$keep/bin/aws" --version 2>/dev/null | awk '{print $1}')" = "aws-cli/$name" ] || return 0

  exes=$(booch_aws_proc_exes "${1:-}")
  # 走査できていれば、少なくとも自分のシェルの exe は読める。中身が無ければ走査自体の失敗（sudo の
  # 拒否など）で、「使用中の版なし」と取り違えて使用中の版まで消さないよう、候補を出さない。
  # 読めないプロセスの行は空行として出るので、空行しか無いときも失敗として扱う。
  if [[ ! $exes =~ [^[:space:]] ]]; then
    echo "aws: 実行中のプロセスを読めないため、使用中の AWS CLI の版を判定できません" >&2
    return 1
  fi
  for d in "${dirs[@]}"; do
    [[ $exes == *"$d/"* ]] || stale+=("$d")
  done
  [ "${#stale[@]}" -gt 0 ] || return 0
  printf '%s\n' "${stale[@]}"
}

# 古い版を削除する（sudo）。job_aws の中では消さない ―― 古い版が溜まった環境では初回の削除が
# 大きく（93 版で約 80 万ファイル）、ジョブのタイムアウトに掛かるため。利用側の cleanup から呼ぶ。
# lib/cleanup.sh の関数と同じく失敗で止めず、常に 0 を返す。候補を判定できないときは何も消さずに
# 理由を stderr へ出す。一部を消せなくても止めない（rm が stderr へ出し、残りは続けて消す）。
booch_aws_cli_prune() {
  local out stale=()
  out=$(booch_aws_cli_stale_versions sudo) || {
    echo "  AWS CLI の古い版の削除を見送りました"
    return 0
  }
  [ -z "$out" ] || mapfile -t stale <<<"$out"
  if [ "${#stale[@]}" -eq 0 ]; then
    echo "  (AWS CLI の古い版はありません)"
    return 0
  fi
  echo "  AWS CLI の古い版を ${#stale[@]} 個削除します"
  sudo rm -rf --one-file-system -- "${stale[@]}" || true
}

# --- Session Manager Plugin ---
booch_aws_ssm_installed_version() {
  command -v session-manager-plugin >/dev/null 2>&1 || return 0
  session-manager-plugin --version 2>/dev/null
}

# 公式配布の最新版（/latest/VERSION）。session-manager-plugin --version と同じ
# "1.2.835.0" 形式で返る。改行を伴わないことがあるので空白・CR を落として正規化する。
booch_aws_ssm_latest() {
  local out
  out=$(curl -fsSL --max-time 15 \
    https://s3.amazonaws.com/session-manager-downloads/plugin/latest/VERSION 2>/dev/null) || return 1
  printf '%s' "$out" | tr -d '[:space:]'
}

# arch → 公式配布の deb ディレクトリ名。
booch_aws_ssm_deb_dir() { # arch
  case "$1" in
    x86_64) printf 'ubuntu_64bit' ;;
    aarch64) printf 'ubuntu_arm64' ;;
    *) echo "aws: SSM 未対応アーキテクチャ: $1" >&2; return 1 ;;
  esac
}

booch_aws_ssm_install() { # arch
  local arch=$1 dir
  dir=$(booch_aws_ssm_deb_dir "$arch") || return 1
  local deb; deb=$(mktemp --suffix=.deb)
  # 発火時に自身を解除し、RETURN トラップが呼び出し元へ漏れて再発火するのを防ぐ
  # （呼び出し元の set -u 下で解放済みローカル変数を踏んで落ちないように）。
  trap 'rm -f "${deb:-}"; trap - RETURN' RETURN
  curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${dir}/session-manager-plugin.deb" \
    -o "$deb" || return 1
  sudo dpkg -i "$deb"
}

job_aws() {
  local arch
  arch=$(booch_aws_arch) || return 1

  # AWS CLI: バージョン比較で更新要否を判定。
  local cur_cli latest_cli
  cur_cli=$(booch_aws_cli_installed_version)
  latest_cli=$(booch_aws_cli_latest) || return 1
  # curl は成功したが版行が取れない（CHANGELOG 形式変化等）場合も、空版での誤 update を
  # 避けるため失敗扱いにする。
  [ -n "$latest_cli" ] || { echo "aws: 最新版を取得できません" >&2; return 1; }
  booch_job_sync "AWS CLI" "aws-cli" "$cur_cli" "$latest_cli" booch_aws_cli_install "$arch"

  # SSM Plugin: /latest/VERSION に upstream の版が出るので、CLI と同じく版比較で更新要否を
  # 判定する（毎回 deb を落とし直すと冪等性を損ねる一方、未導入時のみ導入だと初回の版で
  # 凍結して以後どれだけ古くなっても更新が入らない）。
  # 版を取れないとき（オフライン / 配布側の変更）は、空版での誤 update を避けるため
  # 「未導入なら導入・導入済みは現状維持」へフォールバックする。
  local ssm_cur ssm_latest
  ssm_cur=$(booch_aws_ssm_installed_version)
  ssm_latest=$(booch_aws_ssm_latest) || ssm_latest=""
  if [ -n "$ssm_latest" ]; then
    booch_job_sync "SSM Plugin" "session-manager-plugin" "$ssm_cur" "$ssm_latest" \
      booch_aws_ssm_install "$arch"
  elif [ -z "$ssm_cur" ]; then
    booch_status "installing session-manager-plugin..."
    booch_aws_ssm_install "$arch"
    booch_result "SSM Plugin" installed "" "$(booch_aws_ssm_installed_version)"
  else
    booch_result "SSM Plugin" current "$ssm_cur"
  fi
}
