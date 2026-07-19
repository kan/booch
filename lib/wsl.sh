#!/usr/bin/env bash
# WSL 向けの汎用ユーティリティ。WSL 判定、binfmt interop（.exe 実行）の診断、systemd の有効化。
# 表示文言の最終調整や「この診断を呼ぶか」は利用側が決める。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/wsl.sh"
#   booch_wsl_is_wsl && echo "on WSL"
#   booch_wsl_doctor_interop || warn=1
#   booch_wsl_ensure_systemd            # dockerd/systemctl 前提のツールを入れる前に
#
# 依存: grep。booch_wsl_doctor_interop は 1 行の描画を lib/doctor.sh の booch_doctor_row に
# 委譲する（色・ラベル幅・[OK]/[WARN] の体裁を doctor 本体の他行と揃えるため。利用側は
# doctor.sh を先に source すること）。判定 seam（is_wsl / registered / persisted）は grep のみ。
#
# テスト用の継ぎ目（seam）:
#   booch_wsl_is_wsl                WSL 上か
#   booch_wsl_interop_registered    binfmt_misc に WSLInterop が登録済みか
#   booch_wsl_interop_persisted     binfmt.d に永続設定があるか
#   BOOCH_WSL_CONF                  wsl.conf のパス（既定 /etc/wsl.conf）

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

# WSL の systemd（/etc/wsl.conf の [boot] systemd=true）を有効にする。dockerd や systemctl を
# 前提にするツールの導入前に呼ぶ。既に有効なら何もしない（冪等）。設定ファイルは
# BOOCH_WSL_CONF で差し替えられる（テスト用）。sudo でファイルを書く。
# 反映には WSL の再起動が要るため、書いたときだけ案内を stderr へ出して 0 を返す
# （このまま続行できるが、systemd 前提のジョブは次回実行で有効になる）。
booch_wsl_ensure_systemd() {
  booch_wsl_is_wsl || return 0
  local conf="${BOOCH_WSL_CONF:-/etc/wsl.conf}"
  if grep -qiE "^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true" "$conf" 2>/dev/null; then
    return 0
  fi
  echo "WSL: $conf に systemd=true を設定します（systemd 前提のツールの導入条件）..."
  # 既に [boot] セクションがあればその直後へ差し込む（他セクションを壊さない）。
  if [ -f "$conf" ] && grep -qE "^[[:space:]]*\[boot\]" "$conf"; then
    sudo sed -i "/^[[:space:]]*\[boot\]/a systemd=true" "$conf"
  else
    printf "[boot]\nsystemd=true\n" | sudo tee -a "$conf" >/dev/null
  fi
  printf "  [!] 反映には WSL の再起動が要ります（即時なら Windows 側 wsl --shutdown、または全セッションを\n" >&2
  printf "      閉じて開き直せば VM がアイドル停止→再起動で反映）。再起動後に再実行してください。\n" >&2
}
