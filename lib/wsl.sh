#!/usr/bin/env bash
# WSL 向けの汎用ユーティリティ。WSL 判定と binfmt interop（.exe 実行）の診断。表示文言の
# 最終調整や「この診断を呼ぶか」は利用側が決める。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/wsl.sh"
#   booch_wsl_is_wsl && echo "on WSL"
#   booch_wsl_doctor_interop || warn=1
#
# 依存: grep。booch_wsl_doctor_interop は 1 行の描画を lib/doctor.sh の booch_doctor_row に
# 委譲する（色・ラベル幅・[OK]/[WARN] の体裁を doctor 本体の他行と揃えるため。利用側は
# doctor.sh を先に source すること）。判定 seam（is_wsl / registered / persisted）は grep のみ。
#
# テスト用の継ぎ目（seam）:
#   booch_wsl_is_wsl                WSL 上か
#   booch_wsl_interop_registered    binfmt_misc に WSLInterop が登録済みか
#   booch_wsl_interop_persisted     binfmt.d に永続設定があるか

# WSL 上で動いているか（/proc/version の microsoft か WSL_DISTRO_NAME で判定）。
booch_wsl_is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]
}

# binfmt_misc に WSLInterop が登録され有効か。
booch_wsl_interop_registered() {
  [ -f /proc/sys/fs/binfmt_misc/WSLInterop ] \
    && grep -q "^enabled" /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null
}

# WSLInterop が binfmt.d に永続化されているか。
booch_wsl_interop_persisted() {
  [ -f /usr/lib/binfmt.d/WSLInterop.conf ] || [ -f /etc/binfmt.d/WSLInterop.conf ]
}

# WSL interop（.exe 実行）の登録と永続化を確認して行を表示する。非 WSL なら何もしない。
# 警告があれば非 0 を返す（呼び出し側は `|| warn=1` で受ける）。
booch_wsl_doctor_interop() {
  booch_wsl_is_wsl || return 0
  local warn=0
  echo "--- WSL interop ---"
  if booch_wsl_interop_registered; then
    booch_doctor_row "binfmt_misc registration" ok "enabled"
  else
    booch_doctor_row "binfmt_misc registration" warn "WSLInterop disabled (.exe not runnable from WSL)"
    warn=1
  fi
  if booch_wsl_interop_persisted; then
    booch_doctor_row "persistence config" ok "/usr/lib/binfmt.d/WSLInterop.conf"
  else
    booch_doctor_row "persistence config" warn "not persisted (binfmt-support updates may drop WSLInterop)"
    echo "    sudo tee /usr/lib/binfmt.d/WSLInterop.conf <<'CONF'"
    echo "    :WSLInterop:M::MZ::/init:PF"
    echo "    CONF  -> sudo systemctl restart systemd-binfmt"
    warn=1
  fi
  return "$warn"
}
