#!/usr/bin/env bash
# booch 並列ジョブランナー。
#
# bash-concurrent（vendor/）を土台に、dotfiles 系スクリプトが必要とする
#   - ジョブ単位のタイムアウト（bash-concurrent には無い）
#   - 実行後の結果サマリー（installed / updated / current / migrated / failed）
# を上乗せする。手書きスピナーループ + run_bg_job + write_result + サマリー表示を
# まとめて置き換える基盤。スピナー・チェック・経過秒・失敗ログ表示・終了コードは
# bash-concurrent 側が面倒を見る。
#
# 使い方（source して使う）:
#   export BOOCH_ROOT=/path/to/booch        # 省略時は本ファイルから推定
#   source "$BOOCH_ROOT/lib/runner.sh"
#   booch_runner_init
#   booch_job go     "Go + tools"  job_go     120   # name label fn [timeout秒]
#   booch_job claude "Claude Code" job_claude 0      # timeout 0 = 無効
#   booch_run                                        # 並列実行 → サマリー表示
#
# ジョブ関数（fn）内から呼べるヘルパー:
#   booch_status "downloading..."          # 実行中の 1 行ステータスを更新（fd 3）
#   booch_result "Go" updated 1.22 1.23     # サマリー 1 行を記録
#     status: installed | updated | current | migrated | failed
#
# 要件: bash >= 4.2, GNU coreutils（readlink -f, timeout --foreground --kill-after,
#       mktemp -d）, および bash-concurrent の要件
#       (cat, cp, date, mkdir, mkfifo, mktemp, mv, sed, tail, tput)。
#       WSL2 / Ubuntu を主対象とする（BSD/macOS の readlink/timeout は非互換）。

# BOOCH_ROOT 未設定時のみ本ファイルから推定する。source は caller の set -e 下で
# 走りうるため、readlink/cd の失敗で caller を巻き込まないよう `|| BOOCH_ROOT=""`
# で errexit を抑える（その場合は booch_runner_init が vendor 不在で明示失敗する）。
if [ -z "${BOOCH_ROOT:-}" ]; then
  BOOCH_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd) || BOOCH_ROOT=""
fi

# 色は lib/color.sh に集約（_BOOCH_COLOR_*）。tty/NO_COLOR gate もそこで行う。
# BOOCH_ROOT が取れていれば source する。color.sh が無い（部分チェックアウト等）ときも
# 未定義参照で caller の set -u を巻き込まないよう、空で定義しておく（旧インライン版は
# 常に set だった不変条件を保つ）。
if [ -n "${BOOCH_ROOT:-}" ] && [ -f "$BOOCH_ROOT/lib/color.sh" ]; then
  # shellcheck source=/dev/null
  source "$BOOCH_ROOT/lib/color.sh"
else
  _BOOCH_COLOR_RED=''; _BOOCH_COLOR_YELLOW=''; _BOOCH_COLOR_GREEN=''
  _BOOCH_COLOR_CYAN=''; _BOOCH_COLOR_DIM=''; _BOOCH_COLOR_RESET=''
fi

# 各ジョブの既定タイムアウト（秒）。booch_job の第 4 引数で個別上書き可能。
BOOCH_JOB_TIMEOUT_DEFAULT="${BOOCH_JOB_TIMEOUT_DEFAULT:-120}"

_booch_names=()
_booch_labels=()
_booch_fns=()
_booch_timeouts=()

# vendor を source し、結果記録用ディレクトリを用意する。
booch_runner_init() {
  local lib="$BOOCH_ROOT/vendor/bash-concurrent/concurrent.lib.sh"
  if [ ! -f "$lib" ]; then
    printf '%sERROR:%s vendor が見つかりません: %s\n' "$_BOOCH_COLOR_RED" "$_BOOCH_COLOR_RESET" "$lib" >&2
    echo "  '$BOOCH_ROOT/vendor/update.sh' を実行して bash-concurrent を取得してください" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source "$lib"

  BOOCH_RESULT_DIR=$(mktemp -d) || {
    echo "booch: 結果ディレクトリの作成に失敗しました（mktemp -d）" >&2
    return 1
  }
  export BOOCH_RESULT_DIR

  _booch_names=()
  _booch_labels=()
  _booch_fns=()
  _booch_timeouts=()
}

# ジョブを登録する。name はサマリーのグルーピングキー（結果ファイル名）かつ
# 表示用 label とは別。name はサマリーの正確さのため一意でなければならない
# （重複すると結果ファイルが混ざり二重表示になる）。
booch_job() {
  local name=$1 label=$2 fn=$3 timeout=${4:-$BOOCH_JOB_TIMEOUT_DEFAULT}
  # name は結果ファイル名 "$BOOCH_RESULT_DIR/<name>.result" になるため、ディレクトリ
  # 脱出（/ や ..、先頭 .）と空名を拒否する（lib/apt.sh の repo 名チェックと同方針）。
  case "$name" in
    "" | */* | .*) echo "booch_job: 不正なジョブ名: $name" >&2; return 1 ;;
  esac
  local n
  if [ "${#_booch_names[@]}" -gt 0 ]; then
    for n in "${_booch_names[@]}"; do
      if [ "$n" = "$name" ]; then
        echo "booch_job: ジョブ名が重複しています: $name" >&2
        return 1
      fi
    done
  fi
  _booch_names+=("$name")
  _booch_labels+=("$label")
  _booch_fns+=("$fn")
  _booch_timeouts+=("$timeout")
}

# 実行中ジョブの 1 行ステータスを更新する（ジョブ関数内から呼ぶ）。
# bash-concurrent はタスクの fd 3 への出力を「現在の状態」として表示する。
booch_status() {
  echo "$*" >&3 2>/dev/null || true
}

# サマリーに 1 行追加する（ジョブ関数内から呼ぶ）。
# 同一ジョブ内の複数回呼び出しは登録順に保たれる（同じファイルへ追記）。
booch_result() {
  local tool=$1 status=$2 old_ver=${3:-} new_ver=${4:-}
  printf '%s|%s|%s|%s\n' "$tool" "$status" "$old_ver" "$new_ver" \
    >> "$BOOCH_RESULT_DIR/${BOOCH_JOB:-_}.result"
}

# concurrent から実際に起動されるラッパー。
#
# 実行モデルはタイムアウト有無で一致させる: どちらも `bash -c "set -e; ...; fn"`
# で動かす。timeout は外部コマンドで bash 関数を直接呼べないため declare -f で関数
# 定義を子へ持ち込む必要があり、そのモデルを非 timeout 側にも揃えることで「同じ
# ジョブが timeout 指定の有無で成否が変わる」分岐差（shell オプション・変数継承の
# 違い）を無くす。ジョブは exported 変数 + 関数定義のみに依存する前提になる。
# fd 3（ステータス）と fd 1/2（ログ）は exec をまたいで継承される。
#
# ジョブが非 0 で終わる / timeout に kill される（exit 124/137）と、ジョブ自身は
# failed 行を書けない。ここで rc を捕捉し、失敗時は代わりに failed 行を記録して
# サマリーに必ず現れるようにする（rc はそのまま返し concurrent にも失敗を伝える）。
_booch_exec() {
  local fn=$1 t=$2 name=$3 label=$4
  export BOOCH_JOB="$name"
  local inner
  inner="set -e; $(declare -f); $fn"
  local rc=0
  if [ -n "$t" ] && [ "$t" != "0" ]; then
    timeout --foreground --kill-after=10 "$t" bash -c "$inner" || rc=$?
  else
    bash -c "$inner" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    booch_result "$label" failed
  fi
  return "$rc"
}

# 登録済みジョブを並列実行し、終了後にサマリーを表示する。
# 失敗ジョブがあれば bash-concurrent が末尾にログを出し、本関数も非 0 を返す。
booch_run() {
  if [ "${#_booch_names[@]}" -eq 0 ]; then
    echo "booch_run: 登録済みジョブがありません" >&2
    _booch_cleanup
    return 0
  fi

  local args=() i
  for i in "${!_booch_names[@]}"; do
    args+=( - "${_booch_labels[$i]}" \
            _booch_exec "${_booch_fns[$i]}" "${_booch_timeouts[$i]}" \
                        "${_booch_names[$i]}" "${_booch_labels[$i]}" )
  done

  # bash-concurrent の既定ログ出力先（$PWD/.logs）でカレントを汚さないよう退避。
  local log_dir
  log_dir=$(mktemp -d) || {
    echo "booch: ログディレクトリの作成に失敗しました（mktemp -d）" >&2
    _booch_cleanup
    return 1
  }
  export CONCURRENT_LOG_DIR="$log_dir"

  # bash-concurrent は nounset 非対応（未定義変数を前提に書かれている）。
  # 呼び出し側が set -u でも落ちないよう、concurrent 実行中だけ退避して戻す。
  # concurrent はサブシェル関数なので、ここでの set +u が実行中に継承される。
  local _booch_nounset=0
  case $- in *u*) _booch_nounset=1; set +u ;; esac

  local rc=0
  concurrent "${args[@]}" || rc=$?

  [ "$_booch_nounset" = 1 ] && set -u

  _booch_print_summary

  # 成功時はログを片付ける。失敗時は調査できるよう残す（bash-concurrent が
  # 末尾に保存先パスを案内しているため、消すとその案内が無効になる）。
  if [ "$rc" -eq 0 ]; then
    rm -rf "$log_dir"
  fi
  _booch_cleanup
  return $rc
}

# 結果ディレクトリを片付け、export した変数を caller に残さない。
# CONCURRENT_LOG_DIR は失敗時にディレクトリ自体は残すが（上記参照）、変数は
# 消す（古いパスを caller の後続プロセスに継承させないため）。
_booch_cleanup() {
  [ -n "${BOOCH_RESULT_DIR:-}" ] && rm -rf "$BOOCH_RESULT_DIR"
  unset BOOCH_RESULT_DIR CONCURRENT_LOG_DIR
}

_booch_print_summary() {
  echo ""
  echo "--- Tool Summary ---"
  local name
  for name in "${_booch_names[@]}"; do
    local f="$BOOCH_RESULT_DIR/$name.result"
    [ -f "$f" ] || continue
    local tool status old_ver new_ver
    while IFS='|' read -r tool status old_ver new_ver; do
      case "$status" in
        installed)
          printf '  %s+%s %-25s %sinstalled%s  %s\n' \
            "$_BOOCH_COLOR_GREEN" "$_BOOCH_COLOR_RESET" "$tool" "$_BOOCH_COLOR_GREEN" "$_BOOCH_COLOR_RESET" "$new_ver" ;;
        updated)
          printf '  %s↑%s %-25s %supdated%s    %s → %s\n' \
            "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET" "$tool" "$_BOOCH_COLOR_YELLOW" "$_BOOCH_COLOR_RESET" "$old_ver" "$new_ver" ;;
        current)
          printf '  %s=%s %-25s %slatest%s     %s\n' \
            "$_BOOCH_COLOR_DIM" "$_BOOCH_COLOR_RESET" "$tool" "$_BOOCH_COLOR_DIM" "$_BOOCH_COLOR_RESET" "$old_ver" ;;
        migrated)
          printf '  %s⇄%s %-25s %smigrated%s   %s → %s\n' \
            "$_BOOCH_COLOR_CYAN" "$_BOOCH_COLOR_RESET" "$tool" "$_BOOCH_COLOR_CYAN" "$_BOOCH_COLOR_RESET" "$old_ver" "$new_ver" ;;
        failed)
          printf '  %s✗%s %-25s %sfailed%s\n' \
            "$_BOOCH_COLOR_RED" "$_BOOCH_COLOR_RESET" "$tool" "$_BOOCH_COLOR_RED" "$_BOOCH_COLOR_RESET" ;;
      esac
    done < "$f"
  done
  echo ""
}
