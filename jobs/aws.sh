#!/usr/bin/env bash
# booch 提供ジョブ: AWS CLI v2 と Session Manager Plugin の導入 / 更新（非対話）。
#
# AWS CLI は公式の awscli-exe zip（self-contained installer）、SSM プラグインは公式 .deb
# を使う。どちらも x86_64 / aarch64 に対応する。
#
# 使い方:
#   source "$BOOCH_ROOT/jobs/aws.sh"
#   booch_job aws "AWS CLI + SSM Plugin" job_aws 180
#
# 依存: curl, unzip, dpkg, sudo。
#
# テスト用の継ぎ目（seam）:
#   booch_aws_arch                       uname → x86_64 / aarch64
#   booch_aws_cli_installed_version      現在の aws-cli 版（未導入なら空）
#   booch_aws_cli_latest                 最新 aws-cli 版（公式 CHANGELOG）
#   booch_aws_cli_install <arch>         AWS CLI の導入（副作用）
#   booch_aws_ssm_installed_version      現在の SSM plugin 版（未導入なら空）
#   booch_aws_ssm_install <arch>         SSM plugin の導入（副作用）

booch_aws_arch() {
  case "$(uname -m)" in
    x86_64) printf 'x86_64' ;;
    aarch64 | arm64) printf 'aarch64' ;;
    *) echo "aws: 未対応アーキテクチャ: $(uname -m)" >&2; return 1 ;;
  esac
}

# --- AWS CLI v2 ---
booch_aws_cli_installed_version() {
  command -v aws >/dev/null 2>&1 || return 0
  aws --version 2>/dev/null | awk '{print $1}' | sed 's|aws-cli/||'
}

booch_aws_cli_latest() {
  # curl をパイプにすると失敗が awk の成功で隠れる。変数に捕捉して curl 失敗は return 1。
  local out
  out=$(curl -fsSL --max-time 15 https://raw.githubusercontent.com/aws/aws-cli/v2/CHANGELOG.rst 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk '/^[0-9]+\.[0-9]+\.[0-9]+/{print; exit}'
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
  if [ -z "$cur_cli" ]; then
    booch_status "installing aws-cli ${latest_cli}..."
    booch_aws_cli_install "$arch"
    booch_result "AWS CLI" installed "" "$latest_cli"
  elif [ "$cur_cli" != "$latest_cli" ]; then
    booch_status "updating aws-cli ${cur_cli} -> ${latest_cli}..."
    booch_aws_cli_install "$arch"
    booch_result "AWS CLI" updated "$cur_cli" "$latest_cli"
  else
    booch_result "AWS CLI" current "$cur_cli"
  fi

  # SSM Plugin: 上流に手軽な版取得が無いため latest deb を入れ、前後の版差で結果を出す。
  local old_ssm new_ssm
  old_ssm=$(booch_aws_ssm_installed_version)
  booch_status "installing session-manager-plugin..."
  booch_aws_ssm_install "$arch"
  new_ssm=$(booch_aws_ssm_installed_version)
  if [ -z "$old_ssm" ]; then
    booch_result "SSM Plugin" installed "" "$new_ssm"
  elif [ "$old_ssm" != "$new_ssm" ]; then
    booch_result "SSM Plugin" updated "$old_ssm" "$new_ssm"
  else
    booch_result "SSM Plugin" current "$new_ssm"
  fi
}
