#!/usr/bin/env bash
# lib/wsl.sh のユニットテスト。判定 seam をスタブして検証する。

# stub は間接呼び出しで shellcheck から到達不能に見える
# shellcheck disable=SC2317,SC2329
TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOCH_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export BOOCH_ROOT

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
# booch_wsl_doctor_interop は行描画を booch_doctor_row へ委譲するため doctor.sh も要る。
# shellcheck source=lib/doctor.sh
source "$BOOCH_ROOT/lib/doctor.sh"
# shellcheck source=lib/wsl.sh
source "$BOOCH_ROOT/lib/wsl.sh"

# --- booch_wsl_is_wsl（grep / 環境変数で制御） ---
test_is_wsl_true_via_env() {
  grep() { return 1; }   # /proc/version は microsoft 無し
  WSL_DISTRO_NAME=Ubuntu
  local rc; if booch_wsl_is_wsl; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

test_is_wsl_true_via_proc() {
  grep() { return 0; }   # /proc/version に microsoft あり
  unset WSL_DISTRO_NAME
  local rc; if booch_wsl_is_wsl; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"
}

test_is_wsl_false() {
  grep() { return 1; }
  unset WSL_DISTRO_NAME
  local rc; if booch_wsl_is_wsl; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- booch_wsl_interop_conf（実在パス優先 / 不在でも既定パスを返す） ---
test_interop_conf_returns_existing_path() {
  BOOCH_WSL_INTEROP_CONF="$(mktemp)"
  local out rc
  out=$(booch_wsl_interop_conf) && rc=0 || rc=$?
  assert_status 0 "$rc"
  assert_eq "$BOOCH_WSL_INTEROP_CONF" "$out"
}

# 不在でも空にせず既定パスを返す（案内文が「どこへ書くか」を示せなくなる回帰を防ぐ）。
test_interop_conf_falls_back_to_default_path() {
  BOOCH_WSL_INTEROP_CONF="$(mktemp -u)"
  local out rc
  out=$(booch_wsl_interop_conf) && rc=0 || rc=$?
  assert_status 1 "$rc"
  assert_eq "$BOOCH_WSL_INTEROP_CONF" "$out"
}

test_interop_persisted_follows_conf() {
  BOOCH_WSL_INTEROP_CONF="$(mktemp -u)"
  local rc; if booch_wsl_interop_persisted; then rc=0; else rc=$?; fi
  assert_status 1 "$rc"
}

# --- booch_wsl_binfmt_unit_state（systemctl の有無 / is-enabled で分岐） ---
test_binfmt_unit_state_none_without_systemctl() {
  command() { return 1; }   # systemctl 不在
  assert_eq "none" "$(booch_wsl_binfmt_unit_state)"
}

test_binfmt_unit_state_masked() {
  command() { return 0; }
  systemctl() { echo masked; return 1; }   # is-enabled は masked で非 0 を返す
  assert_eq "masked" "$(booch_wsl_binfmt_unit_state)"
}

test_binfmt_unit_state_present() {
  command() { return 0; }
  systemctl() { echo static; }
  assert_eq "present" "$(booch_wsl_binfmt_unit_state)"
}

# --- booch_wsl_doctor_interop（is_wsl / registered / persisted / unit を seam で固定） ---
# 実機の systemd 状態に結果が左右されないよう、全テストで unit 状態も固定する。
_stub_interop_all_good() {
  booch_wsl_is_wsl() { return 0; }
  booch_wsl_interop_registered() { return 0; }
  booch_wsl_interop_persisted() { return 0; }
  booch_wsl_binfmt_unit_state() { echo present; }
}

test_doctor_interop_noop_when_not_wsl() {
  booch_wsl_is_wsl() { return 1; }
  local out; out=$(booch_wsl_doctor_interop)
  assert_eq "" "$out"   # 非 WSL は何も出さない
}

test_doctor_interop_ok_when_all_good() {
  _stub_interop_all_good
  local rc; if booch_wsl_doctor_interop >/dev/null; then rc=0; else rc=$?; fi
  assert_status 0 "$rc"   # 警告なし → 0
}

# OK 行が GREEN で色付けされること（他 doctor 行と揃える。生 echo だと無色になる回帰を防ぐ）。
test_doctor_interop_ok_is_green() {
  _stub_interop_all_good
  local _BOOCH_COLOR_GREEN='<G>' _BOOCH_COLOR_RESET='<R>'
  local out; out=$(booch_wsl_doctor_interop)
  assert_contains "$out" "<G>[OK]<R>  enabled"
  assert_contains "$out" "<G>[OK]<R>  /usr/lib/binfmt.d/WSLInterop.conf"
}

# 行の体裁（ラベル幅 + [OK] の桁）が booch_doctor_row と完全一致すること。生 printf を
# 手書きしていた頃は 1 桁ずれていた回帰を、描画委譲で防いだことのガード。
test_doctor_interop_row_matches_doctor_row() {
  _stub_interop_all_good
  local out expected
  out=$(booch_wsl_doctor_interop)
  expected=$(booch_doctor_row "binfmt_misc registration" ok "enabled")
  assert_contains "$out" "$expected"
}

test_doctor_interop_warns_when_not_registered() {
  _stub_interop_all_good
  booch_wsl_interop_registered() { return 1; }
  local out rc
  out=$(booch_wsl_doctor_interop) && rc=0 || rc=$?
  assert_status 1 "$rc"
  assert_contains "$out" "WSLInterop disabled"
}

# 永続化済みで登録だけ落ちたケース（今回の実障害）に、即時復旧コマンドが出ること。
# 従来はこの組み合わせで「disabled」とだけ出て、何をすればよいか案内が無かった。
test_doctor_interop_hints_register_when_only_registration_lost() {
  _stub_interop_all_good
  booch_wsl_interop_registered() { return 1; }
  booch_wsl_interop_conf() { echo /usr/lib/binfmt.d/WSLInterop.conf; }
  local out; out=$(booch_wsl_doctor_interop) || true
  assert_contains "$out" "/proc/sys/fs/binfmt_misc/register"
  assert_contains "$out" "/usr/lib/binfmt.d/WSLInterop.conf"
}

test_doctor_interop_warns_when_not_persisted() {
  _stub_interop_all_good
  booch_wsl_interop_persisted() { return 1; }
  local out rc
  out=$(booch_wsl_doctor_interop) && rc=0 || rc=$?
  assert_status 1 "$rc"
  assert_contains "$out" "not persisted"
}

# masked を検出して unmask を案内すること。masked だと登録が消えても戻る経路が無く、
# しかも旧案内（systemctl restart systemd-binfmt）は黙って空振りする。
test_doctor_interop_warns_when_unit_masked() {
  _stub_interop_all_good
  booch_wsl_binfmt_unit_state() { echo masked; }
  local out rc
  out=$(booch_wsl_doctor_interop) && rc=0 || rc=$?
  assert_status 1 "$rc"
  assert_contains "$out" "masked"
  assert_contains "$out" "systemctl unmask systemd-binfmt.service"
}

# systemd 非搭載（systemctl 無し）では unit 行を出さない（無関係な warn を増やさない）。
test_doctor_interop_omits_unit_row_without_systemd() {
  _stub_interop_all_good
  booch_wsl_binfmt_unit_state() { echo none; }
  local out rc
  out=$(booch_wsl_doctor_interop) && rc=0 || rc=$?
  assert_status 0 "$rc"
  assert_not_contains "$out" "systemd-binfmt unit"
}

# 空振りする旧案内（masked だと何も起きない restart）を復活させない。
test_doctor_interop_does_not_suggest_restart() {
  _stub_interop_all_good
  booch_wsl_interop_registered() { return 1; }
  booch_wsl_interop_persisted() { return 1; }
  local out; out=$(booch_wsl_doctor_interop) || true
  assert_not_contains "$out" "systemctl restart systemd-binfmt"
}


# --- booch_wsl_ensure_systemd（BOOCH_WSL_CONF を temp に向け、sudo をスタブして実処理を検証） ---
# sudo は素通し（テストは temp ファイルを書くだけ）。
_setup_wsl_conf() {
  BOOCH_WSL_CONF="$(mktemp)"
  sudo() { "$@"; }
  booch_wsl_is_wsl() { return 0; }
}

test_ensure_systemd_noop_when_not_wsl() {
  _setup_wsl_conf
  booch_wsl_is_wsl() { return 1; }
  : > "$BOOCH_WSL_CONF"
  local out; out=$(booch_wsl_ensure_systemd 2>&1)
  assert_eq "" "$out"
  assert_eq "" "$(cat "$BOOCH_WSL_CONF")"
}

test_ensure_systemd_noop_when_already_enabled() {
  _setup_wsl_conf
  printf '[boot]\nsystemd=true\n' > "$BOOCH_WSL_CONF"
  local out; out=$(booch_wsl_ensure_systemd 2>&1)
  assert_eq "" "$out"
}

test_ensure_systemd_appends_boot_section_when_missing() {
  _setup_wsl_conf
  printf '[automount]\nenabled=true\n' > "$BOOCH_WSL_CONF"
  booch_wsl_ensure_systemd >/dev/null 2>&1
  local conf; conf=$(cat "$BOOCH_WSL_CONF")
  assert_contains "$conf" "[boot]"
  assert_contains "$conf" "systemd=true"
  assert_contains "$conf" "[automount]"   # 既存セクションを壊さない
}

test_ensure_systemd_inserts_into_existing_boot_section() {
  _setup_wsl_conf
  printf '[boot]\ncommand=echo hi\n' > "$BOOCH_WSL_CONF"
  booch_wsl_ensure_systemd >/dev/null 2>&1
  local conf; conf=$(cat "$BOOCH_WSL_CONF")
  # [boot] は 1 つのまま（重複セクションを作らない）
  assert_eq "1" "$(grep -c '^\[boot\]' "$BOOCH_WSL_CONF")"
  assert_contains "$conf" "systemd=true"
  assert_contains "$conf" "command=echo hi"
}

test_ensure_systemd_is_idempotent() {
  _setup_wsl_conf
  : > "$BOOCH_WSL_CONF"
  booch_wsl_ensure_systemd >/dev/null 2>&1
  booch_wsl_ensure_systemd >/dev/null 2>&1
  assert_eq "1" "$(grep -c 'systemd=true' "$BOOCH_WSL_CONF")"
}

test_ensure_systemd_warns_about_restart() {
  _setup_wsl_conf
  : > "$BOOCH_WSL_CONF"
  local err; err=$(booch_wsl_ensure_systemd 2>&1 >/dev/null)
  assert_contains "$err" "wsl --shutdown"
}

run_tests
