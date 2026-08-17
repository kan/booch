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
# 依存: grep（systemd-binfmt の状態を見るときだけ systemctl。無ければ none として扱う）。
# booch_wsl_doctor_interop は 1 行の描画を lib/doctor.sh の booch_doctor_row に委譲する
# （色・ラベル幅・[OK]/[WARN] の体裁を doctor 本体の他行と揃えるため。利用側は doctor.sh を
# 先に source すること）。
#
# テスト用の継ぎ目（seam）:
#   booch_wsl_is_wsl                 WSL 上か
#   booch_wsl_interop_registered     binfmt_misc に WSLInterop が登録済みか
#   booch_wsl_interop_conf           binfmt.d の永続設定パス（無ければ既定パス＋非 0）
#   booch_wsl_interop_persisted      binfmt.d に永続設定があるか
#   booch_wsl_binfmt_unit_state      systemd-binfmt.service の状態（masked / present / none）
#   BOOCH_WSL_CONF                   wsl.conf のパス（既定 /etc/wsl.conf）
#   BOOCH_WSL_INTEROP_CONF           永続設定の既定パス（既定 /usr/lib/binfmt.d/WSLInterop.conf）

# WSLInterop の binfmt.d 永続設定を置く既定パス。
BOOCH_WSL_INTEROP_CONF=${BOOCH_WSL_INTEROP_CONF:-/usr/lib/binfmt.d/WSLInterop.conf}

# WSL 上で動いているか（/proc/version の microsoft か WSL_DISTRO_NAME で判定）。
booch_wsl_is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]
}

# binfmt_misc に WSLInterop が登録され有効か。
booch_wsl_interop_registered() {
  [ -f /proc/sys/fs/binfmt_misc/WSLInterop ] \
    && grep -q "^enabled" /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null
}

# 実在する永続設定のパスを表示する。見つからなければ既定パスを表示して非 0 を返す
# （案内文が「どこへ書くか」を常に示せるよう、不在時も空にしない）。
booch_wsl_interop_conf() {
  local p
  for p in "$BOOCH_WSL_INTEROP_CONF" /etc/binfmt.d/WSLInterop.conf; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  printf '%s\n' "$BOOCH_WSL_INTEROP_CONF"
  return 1
}

# WSLInterop が binfmt.d に永続化されているか。
booch_wsl_interop_persisted() {
  booch_wsl_interop_conf >/dev/null
}

# systemd-binfmt.service の状態を表示する。masked / present（それ以外）/ none（systemd 無し）。
# masked だと binfmt.d の再適用も、WSL が drop-in で仕込む WSLInterop 再登録も走らないため、
# 「登録が消えたら二度と戻らない」状態になる。
booch_wsl_binfmt_unit_state() {
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'none\n'
    return
  fi
  if [ "$(systemctl is-enabled systemd-binfmt.service 2>/dev/null)" = masked ]; then
    printf 'masked\n'
  else
    printf 'present\n'
  fi
}

# WSL interop（.exe 実行）の登録・永続化・再登録経路を確認して行を表示する。非 WSL なら
# 何もしない。警告があれば非 0 を返す（呼び出し側は `|| warn=1` で受ける）。
# 警告行には復旧コマンドを添える。**即時復旧は binfmt_misc の register へ直接書く**形にして
# あり、`systemctl restart systemd-binfmt` に頼らない（後者はユニットが masked だと黙って
# 何もしないため、案内が空振りする）。
booch_wsl_doctor_interop() {
  booch_wsl_is_wsl || return 0
  local warn=0 conf persisted=0 unit
  conf=$(booch_wsl_interop_conf)
  booch_wsl_interop_persisted && persisted=1
  unit=$(booch_wsl_binfmt_unit_state)
  echo "--- WSL interop ---"
  if booch_wsl_interop_registered; then
    booch_doctor_row "binfmt_misc registration" ok "enabled"
  else
    booch_doctor_row "binfmt_misc registration" warn "WSLInterop disabled (.exe not runnable from WSL)"
    if [ "$persisted" = 1 ]; then
      printf "    今すぐ戻す: sudo sh -c 'cat %s > /proc/sys/fs/binfmt_misc/register'\n" "$conf"
    else
      printf '    先に下の persistence config を作ってから登録する\n'
    fi
    warn=1
  fi
  if [ "$persisted" = 1 ]; then
    booch_doctor_row "persistence config" ok "$conf"
  else
    booch_doctor_row "persistence config" warn "not persisted (binfmt-support updates may drop WSLInterop)"
    printf "    sudo tee %s <<'CONF'\n" "$conf"
    printf '    :WSLInterop:M::MZ::/init:PF\n'
    printf '    CONF\n'
    printf "    そのうえで: sudo sh -c 'cat %s > /proc/sys/fs/binfmt_misc/register'\n" "$conf"
    warn=1
  fi
  case "$unit" in
    masked)
      booch_doctor_row "systemd-binfmt unit" warn "masked (binfmt.d reapply / WSLInterop re-register never run)"
      printf '    sudo systemctl unmask systemd-binfmt.service && sudo systemctl daemon-reload\n'
      warn=1 ;;
    present)
      booch_doctor_row "systemd-binfmt unit" ok "not masked" ;;
  esac
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
