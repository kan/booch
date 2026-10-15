#!/usr/bin/env bash
# booch 提供ジョブ: Codex CLI の導入 / 更新（非対話）。
#
# 公式インストーラ（https://chatgpt.com/codex/install.sh）で導入と更新をする。Codex CLI は本体の
# ほかに付随の実行ファイル（codex-code-mode-host / rg / サンドボックス用の bwrap）をパッケージと
# して同梱しており、GitHub Releases の単体バイナリだけを置いても正常に動かない。インストーラは
# $CODEX_HOME/packages/standalone/releases/<版>-<target> へパッケージを展開し（SHA256 は
# インストーラが照合する）、同じ階層の current をその版へ向け、$CODEX_INSTALL_DIR（既定
# ~/.local/bin）に codex の symlink を張る。sudo は使わない。
#
# 更新も同じ経路で行う。導入済みの版と GitHub の最新タグを比べ、違えばその版を指定して
# インストーラを実行し直す（current が新しい版へ張り替わる）。インストーラは古い版を消さない
# （1 版あたり数百 MB）ので、導入後に current と直前の版以外を削除する。直前の版を残すのは、
# 更新前から動いている codex のセッションが自分の版の付随ファイルを起動し続けるため。
#
# **PATH は利用側で通す。** インストーラは導入先が PATH に無いとシェルの設定ファイル
# （~/.bashrc 等）へ PATH の追記ブロックを書き込む。設定ファイルを dotfiles で管理している
# 環境ではその書き込みが管理対象へ混入するため、インストーラには一時ディレクトリを HOME として
# 渡し、追記を捨てる（CODEX_HOME と導入先は元の HOME を基準に明示して渡す）。
#
# 以前の booch が置いていた単体バイナリ（/usr/local/bin/codex）は、インストーラでの導入が
# 済んでいれば毎回の実行で削除を試みる。残すと PATH の順序しだいで古い単体バイナリが起動され
# 続けるため。撤去するのは booch 自身が置いた物だけで、npm 版など他の経路で入った codex の
# 撤去は利用側に任せる。
#
# **共有デーモン（app-server）の版は job_codex では合わせない。** TUI などが使うバックグラウンドの
# デーモンは自分用の codex（$CODEX_HOME/packages/app-server-daemon/）で動くので、CLI を更新しても
# 動いているデーモンは古い版のまま残る（Codex は起動時に版のずれを警告する）。stop → start /
# restart ではデーモン用の codex を入れ直さず、直るのは `codex app-server daemon update` だけ。
# update は実行中の作業を中断しうるため、確認を挟む booch_codex_daemon_sync を用意してある。
# ジョブは非対話なので、利用側が booch_run の後に主シェルから呼ぶ。版を表示するだけ（doctor 等）
# なら booch_codex_daemon_versions を使う。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/arch.sh"
#   source "$BOOCH_ROOT/lib/github.sh"
#   source "$BOOCH_ROOT/jobs/codex.sh"
#   booch_job codex "Codex CLI" job_codex 300
#   booch_run ...
#   source "$BOOCH_ROOT/lib/confirm.sh"
#   booch_codex_daemon_sync || warn=1      # 主シェルの後段で（ジョブの中では呼ばない）
#
# 依存: lib/arch.sh, lib/github.sh, curl, jq, sh, tar, find, timeout。旧単体バイナリの削除時だけ
# sudo。booch_codex_daemon_sync は lib/confirm.sh も使う。
#
# テスト用の継ぎ目（seam）:
#   booch_codex_installed_version  インストーラが導入した codex の版（未導入なら空）
#   booch_codex_latest             最新タグ（rust-vX.Y.Z 形式）
#   booch_codex_arch               対応アーキの確認（x86_64 / aarch64）
#   booch_codex_install <version>  実際の導入（副作用。version は rust-v を外した X.Y.Z）
#   booch_codex_fetch_installer <dest>  インストーラの取得
#   booch_codex_run_installer <script> <version>  インストーラの実行
#   booch_codex_legacy_path        以前の booch が置いた単体バイナリのパス
#   booch_codex_daemon_version_json  `codex app-server daemon version` の JSON（停止中は 1、応答なしは 124）
#   booch_codex_daemon_update      `codex app-server daemon update`（副作用）

# インストーラの導入先（codex の symlink を置くディレクトリ）。インストーラと同じ既定値。
booch_codex_bin_dir() {
  printf '%s' "${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
}

# Codex のホーム。インストーラと同じ既定値。
booch_codex_home() {
  printf '%s' "${CODEX_HOME:-$HOME/.codex}"
}

# インストーラがパッケージを置くディレクトリ（releases/ と current を持つ）。
booch_codex_standalone_dir() {
  printf '%s' "$(booch_codex_home)/packages/standalone"
}

booch_codex_installed_version() {
  # PATH 上の codex ではなく導入先を見る。旧単体バイナリや npm 版が PATH に残っていても、
  # インストーラでの導入が済んでいなければ未導入として扱い、導入を走らせるため。
  local bin; bin="$(booch_codex_bin_dir)/codex"
  [ -x "$bin" ] || return 0
  # `codex --version` は "codex-cli 0.142.3" 形式。末尾にハッシュ等が付いても壊れない
  # よう、位置ではなく X.Y.Z パターンで最初の版を取り出す（取れなければ空＝未導入扱い）。
  "$bin" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

booch_codex_latest() {
  booch_github_latest_tag openai/codex
}

# 対応アーキの確認（x86_64 / aarch64）。インストーラも判定するが、非対応なら取得前に止める。
booch_codex_arch() { booch_arch_rust_style; }

booch_codex_fetch_installer() { # dest
  curl -fsSL --max-time 60 https://chatgpt.com/codex/install.sh -o "$1"
}

booch_codex_run_installer() { # script version
  local script=$1 version=$2
  local codex_home; codex_home=$(booch_codex_home)
  local bin_dir; bin_dir=$(booch_codex_bin_dir)
  local fake_home; fake_home=$(mktemp -d)
  # 発火時に自身を解除し、RETURN トラップが呼び出し元へ漏れて再発火するのを防ぐ
  # （呼び出し元の set -u 下で解放済みローカル変数を踏んで落ちないように）。
  trap 'rm -rf "${fake_home:-}"; trap - RETURN' RETURN
  HOME="$fake_home" CODEX_HOME="$codex_home" CODEX_INSTALL_DIR="$bin_dir" \
    CODEX_NON_INTERACTIVE=true sh "$script" --release "$version"
}

# current が指す版ディレクトリの名前（<版>-<target>）。current が無ければ空。
booch_codex_current_release() {
  local target
  target=$(readlink "$(booch_codex_standalone_dir)/current" 2>/dev/null) || return 0
  printf '%s' "${target##*/}"
}

# current と keep（直前の版の名前）以外の版ディレクトリを削除する。作業中の .staging.* は
# インストーラ自身が掃除するので触らない。比較は名前で行う（パスで比べると、途中の
# symlink や `//` の有無で一致せず、current まで消してしまう）。
booch_codex_prune_releases() { # [keep]
  local keep=${1:-}
  local current; current=$(booch_codex_current_release)
  [ -n "$current" ] || return 0
  local dir name
  while IFS= read -r dir; do
    name=${dir##*/}
    [ "$name" = "$current" ] && continue
    [ -n "$keep" ] && [ "$name" = "$keep" ] && continue
    rm -rf "$dir"
  done < <(find "$(booch_codex_standalone_dir)/releases" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null)
}

booch_codex_legacy_path() { printf '/usr/local/bin/codex'; }

# 以前の booch が置いた単体バイナリを削除する。消すのは symlink ではない実ファイルで、
# `--version` が codex-cli を名乗るときだけ（同名の別物を巻き込まない）。
booch_codex_remove_legacy() {
  local legacy; legacy=$(booch_codex_legacy_path)
  [ -f "$legacy" ] && [ ! -L "$legacy" ] || return 0
  "$legacy" --version 2>/dev/null | grep -q '^codex-cli ' || return 0
  sudo rm -f "$legacy"
}

booch_codex_install() { # version
  local version=$1
  local previous; previous=$(booch_codex_current_release)
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"; trap - RETURN' RETURN
  booch_codex_fetch_installer "$tmp/install.sh" || return 1
  # インストーラの進捗表示はジョブのログへ流す（ステータス行は booch_job_sync が出す）。
  booch_codex_run_installer "$tmp/install.sh" "$version" >&2 || return 1
  booch_codex_prune_releases "$previous"
}

job_codex() {
  local current latest
  booch_codex_arch >/dev/null || return 1
  current=$(booch_codex_installed_version)
  latest=$(booch_codex_latest) || return 1
  # タグは rust-vX.Y.Z。codex --version もインストーラの --release も素の版なので、
  # rust-v / v を外して比較と導入の両方に使う。
  latest=${latest#rust-v}
  latest=${latest#v}
  booch_job_sync "Codex CLI" "codex" "$current" "$latest" booch_codex_install "$latest"
  # 旧単体バイナリの削除は、版の比較とは独立に毎回試す。導入と同じ回に削除だけ失敗すると
  # （sudo の失敗など）、次回は版が一致して導入が呼ばれず、削除が再試行されなくなるため。
  # インストーラでの導入が済んでいるときだけ消す（未導入のまま codex を失わないように）。
  [ -x "$(booch_codex_bin_dir)/codex" ] || return 0
  if ! booch_codex_remove_legacy; then
    echo "codex: 旧単体バイナリの削除に失敗: $(booch_codex_legacy_path)" >&2
    return 1
  fi
}

# --- 共有デーモン（app-server）の版合わせ（ジョブではなく主シェルから呼ぶ） ---

# `daemon version` は cliVersion と appServerVersion を JSON で返す。止まっていれば exit 1 で、
# デーモンを起動しない。応答しないデーモンで setup / doctor を止めないよう上限を付ける
# （応答しなければ timeout の 124 / 137 が返る）。
booch_codex_daemon_version_json() {
  timeout --kill-after=2 5 "$(booch_codex_bin_dir)/codex" app-server daemon version 2>/dev/null
}

# デーモン用の codex を更新し、動いているデーモンを新しい版で起こし直す（最新なら何もしない）。
# SIGTERM を無視されても setup が固まらないよう、猶予の後に kill する。
booch_codex_daemon_update() {
  timeout --kill-after=10 120 "$(booch_codex_bin_dir)/codex" app-server daemon update >/dev/null
}

# "<cli> <app>" の 1 行を出す。デーモンが止まっていれば app は空。取れなければ非 0。
# CLI は PATH 上ではなく導入先の codex を見る（booch_codex_installed_version と出どころを揃える）。
booch_codex_daemon_versions() {
  local json rc=0 cli
  [ -x "$(booch_codex_bin_dir)/codex" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  json=$(booch_codex_daemon_version_json) || rc=$?
  if [ "$rc" -eq 0 ]; then
    jq -er '"\(.cliVersion // empty) \(.appServerVersion // "")"' <<<"$json" 2>/dev/null
    return
  fi
  # 応答しない（timeout）ときは停止中と区別して非 0 にする。それ以外の失敗は停止中として扱う
  # （停止中も、クラッシュで残ったソケットへの接続失敗も exit 1 で、区別する手段が無い）。
  case "$rc" in 124 | 137) return 1 ;; esac
  cli=$(booch_codex_installed_version)
  [ -n "$cli" ] || return 1
  printf '%s \n' "$cli"
}

# デーモンの版が CLI とずれていれば y/N を聞いて update する。実行中の作業が中断されうるので、
# assume_yes は受け取らず確認を省かない（非対話なら何もしない）。ずれていない / 停止中 / 版が
# 取れないときも何もせず 0。確認手段（lib/confirm.sh）を読めないときと、update しても版が
# そろわないときは 1 を返すので、set -e の caller は `booch_codex_daemon_sync || warn=1` で受ける。
booch_codex_daemon_sync() {
  local cli app line i now=
  read -r cli app < <(booch_codex_daemon_versions) || return 0
  [ -n "$app" ] && [ "$cli" != "$app" ] || return 0
  # 確認を挟めないまま中断を伴う update へ進まないよう、confirm.sh が無ければ失敗にする
  # （「常に no」で黙って見送ると、ずれが直らないまま気付かれない）。
  if ! declare -F booch_confirm_yes_no >/dev/null 2>&1; then
    if [ -n "${BOOCH_ROOT:-}" ] && [ -f "$BOOCH_ROOT/lib/confirm.sh" ]; then
      # shellcheck source=lib/confirm.sh
      source "$BOOCH_ROOT/lib/confirm.sh"
    else
      echo "Codex: lib/confirm.sh を読み込めないため、デーモンの版のずれを直せません" >&2
      return 1
    fi
  fi
  echo "Codex: CLI $cli / デーモン $app（版がずれています）"
  if ! booch_confirm_yes_no "Codex のデーモンを入れ替えますか？（実行中の作業は中断されます）"; then
    echo "Codex: デーモンの入れ替えをスキップしました（codex の /daemon か codex app-server daemon update で直せます）"
    return 0
  fi
  echo "Codex: デーモンを入れ替えています..."
  booch_codex_daemon_update || echo "Codex: codex app-server daemon update が失敗しました（rc=$?）" >&2
  # 入れ替えた直後は、起動しきっておらず版を読めないことや、古いデーモンがまだ応答していることが
  # あるので、版がそろうまで数回読み直す。
  for i in 1 2 3 4 5; do
    if line=$(booch_codex_daemon_versions); then
      now=${line#* }
      [ -n "$now" ] && [ "$now" = "$cli" ] && break
    else
      now="（応答なし）"
    fi
    [ "$i" -lt 5 ] && sleep 1
  done
  if [ "$now" = "$cli" ]; then
    echo "Codex: デーモンを入れ替えました（$now）"
    return 0
  fi
  echo "Codex: デーモンを入れ替えられませんでした（CLI $cli / デーモン ${now:-停止中}）" >&2
  return 1
}
