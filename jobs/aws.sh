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
# 依存: lib/arch.sh, curl, unzip, dpkg, sudo。
#
# テスト用の継ぎ目（seam）:
#   booch_aws_arch                       uname → x86_64 / aarch64
#   booch_aws_cli_installed_version      現在の aws-cli 版（未導入なら空）
#   booch_aws_cli_latest                 最新 aws-cli 版（公式 CHANGELOG）
#   booch_aws_cli_install <arch>         AWS CLI の導入（副作用）
#   booch_aws_ssm_installed_version      現在の SSM plugin 版（未導入なら空）
#   booch_aws_ssm_install <arch>         SSM plugin の導入（副作用）

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
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp/awscli.zip" || return 1
  unzip -q "$tmp/awscli.zip" -d "$tmp" || return 1
  sudo "$tmp/aws/install" --update
}

# --- Session Manager Plugin ---
booch_aws_ssm_installed_version() {
  command -v session-manager-plugin >/dev/null 2>&1 || return 0
  session-manager-plugin --version 2>/dev/null
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
  trap 'rm -f "$deb"' RETURN
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

  # SSM Plugin: upstream に版確認の手段が無く /latest/ しか無いため、毎回再取得すると冪等性
  # （再実行で無駄に再取得しない）を損ね、オフライン時に現状維持できず失敗する。未導入のとき
  # だけ導入し、導入済みは現状維持（current）とする。更新したいときは利用側がプラグインを
  # 消して再実行する。
  local ssm_ver
  ssm_ver=$(booch_aws_ssm_installed_version)
  if [ -z "$ssm_ver" ]; then
    booch_status "installing session-manager-plugin..."
    booch_aws_ssm_install "$arch"
    booch_result "SSM Plugin" installed "" "$(booch_aws_ssm_installed_version)"
  else
    booch_result "SSM Plugin" current "$ssm_ver"
  fi
}
