#!/usr/bin/env bash
# アーキテクチャ名の解決。`uname -m` を配布側の命名へ写す。配布物の命名は 2 系統あり、
# 各ジョブは自分の seam（booch_<tool>_arch）をこれらの薄いラッパーにする。
#
#   dpkg 系   : x86_64 → amd64 / aarch64 → arm64    （Go tarball, CircleCI 等）
#   rust 系   : x86_64 → x86_64 / aarch64 → aarch64  （Codex, AWS CLI 等）
#
# dpkg --print-architecture を直接読む必要があるもの（delta の .deb 等）は uname 写しでは
# 表せないため、そのジョブ側で個別に持つ。

booch_arch_dpkg_style() {
  local m; m=$(uname -m)
  case "$m" in
    x86_64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) echo "arch: 未対応アーキテクチャ: $m" >&2; return 1 ;;
  esac
}

booch_arch_rust_style() {
  local m; m=$(uname -m)
  case "$m" in
    x86_64) printf 'x86_64' ;;
    aarch64 | arm64) printf 'aarch64' ;;
    *) echo "arch: 未対応アーキテクチャ: $m" >&2; return 1 ;;
  esac
}
