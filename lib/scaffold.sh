#!/usr/bin/env bash
# 利用側 dotfiles リポジトリの雛形を生成する。booch は「汎用ブートストラップ基盤」であり、
# 個人固有の設定（symlink・トークン・custom job 等）は利用側 dotfiles に置く方針。本ヘルパーは
# その出発点（推奨構成 + 最小サンプル）をコマンド一発で作る。`bin/booch init <dir>` の実体。
#
# 使い方:
#   source "$BOOCH_ROOT/lib/scaffold.sh"
#   booch_scaffold ~/dotfiles
#
# 方針: 既存ファイルは上書きしない（冪等。再実行で created/skip を表示するだけ）。生成物には
# 個人固有・業務固有の値を埋め込まず、プレースホルダ（<...> / edit me）で示す。
#
# 依存: mkdir, cat, chmod, dirname（GNU coreutils）。network / sudo は使わない。

# 内容（stdin）を path へ書く。既存なら上書きせず skip（stdin は捨てる）。冪等性の要。
_booch_scaffold_write() { # path  (content on stdin)
  local path=$1
  if [ -e "$path" ]; then
    cat >/dev/null
    echo "skip（既存）: $path"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  echo "created: $path"
}

# <dir> に dotfiles 雛形を生成する。
booch_scaffold() { # dir
  local dir=${1:-}
  if [ -z "$dir" ]; then
    echo "scaffold: 生成先ディレクトリを指定してください（例: booch init ~/dotfiles）" >&2
    return 1
  fi
  mkdir -p "$dir"

  # エントリスクリプト。booch を source → custom job 登録 → booch_run。
  _booch_scaffold_write "$dir/bootstrap.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
# 自分の開発環境をブートストラップするエントリスクリプト（booch init が生成した雛形）。
# booch（汎用ランナー）を source し、自分用の custom job と booch 提供ジョブを登録して
# 並列実行する。自分の構成に合わせて編集すること。
# shellcheck disable=SC2317   # job_* は runner が bash -c 経由で間接実行する
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# booch 本体は git submodule で vendor/booch に取り込むのを推奨する:
#   git submodule add https://github.com/kan/booch vendor/booch
export BOOCH_ROOT="${BOOCH_ROOT:-$HERE/vendor/booch}"
if [ ! -f "$BOOCH_ROOT/lib/runner.sh" ]; then
  echo "booch が見つかりません: $BOOCH_ROOT" >&2
  echo "  git submodule add https://github.com/kan/booch vendor/booch" >&2
  echo "  git submodule update --init --recursive" >&2
  exit 1
fi
source "$BOOCH_ROOT/lib/runner.sh"
source "$BOOCH_ROOT/lib/fs.sh"

booch_runner_init

# --- custom job（個人固有処理はここ。booch 本体には持ち込まない）---
for f in "$HERE"/jobs/*.sh; do
  [ -e "$f" ] || continue
  # shellcheck source=/dev/null
  source "$f"
done

# 例: symlink 配置（lib/fs.sh）。<実体 → 配置先> を自分の構成に合わせて書く。
# booch_symlink "$HERE/config/bashrc" "$HOME/.bashrc"

# custom job を登録（jobs/example.sh が job_example を定義している前提）。
booch_job example "example custom job" job_example 60

# booch 提供ジョブ（go / delta / codex / aws / circleci）を使う場合は submodule 側を
# source して登録する。多くは sudo を使うので booch_run の前に認証をキャッシュすると良い:
#   source "$BOOCH_ROOT/lib/sudo.sh"; booch_sudo_prime || exit 1; trap 'booch_sudo_stop' EXIT
#   source "$BOOCH_ROOT/lib/arch.sh"; source "$BOOCH_ROOT/lib/verify.sh"
#   source "$BOOCH_ROOT/jobs/go.sh"; booch_job go "Go" job_go 300

booch_run
BOOTSTRAP
  chmod +x "$dir/bootstrap.sh" 2>/dev/null || true

  # custom job のサンプル。
  _booch_scaffold_write "$dir/jobs/example.sh" <<'JOB'
#!/usr/bin/env bash
# custom job のサンプル。個人固有の処理（特定リポジトリの clone/pull・社内ツール導入・
# 設定ファイルの配置など）はこのように利用側に置き、booch 本体には持ち込まない。
# ジョブは非対話・別プロセスで動くため、依存できるのは exported 変数と関数定義だけ。
# shellcheck disable=SC2317   # job_* は runner が bash -c 経由で間接実行する

job_example() {
  booch_status "running example job..."
  # ここに自分の処理を書く（例: ディレクトリ用意・リポジトリ pull・ツール導入）。
  booch_result "example" current "(edit me)"
}
JOB

  # symlink で配置する設定ファイルの置き場（プレースホルダ）。
  _booch_scaffold_write "$dir/config/README.md" <<'CONFIGREADME'
# config

symlink で `$HOME` 配下へ配置する設定ファイルの実体を置く。`bootstrap.sh` の
`booch_symlink "$HERE/config/<file>" "$HOME/<dest>"` で張る。

例: `config/bashrc` を置き、`booch_symlink "$HERE/config/bashrc" "$HOME/.bashrc"`。
CONFIGREADME

  _booch_scaffold_write "$dir/.gitignore" <<'GITIGNORE'
# 個人固有・秘匿情報はコミットしない
*.local
.env
secrets/
GITIGNORE

  _booch_scaffold_write "$dir/README.md" <<'READMETPL'
# dotfiles

<自分の開発環境の dotfiles。[booch](https://github.com/kan/booch) を使ってブートストラップする。>

## セットアップ

```bash
git submodule add https://github.com/kan/booch vendor/booch   # 初回のみ
git -C vendor/booch checkout <最新リリースタグ>                # 例: v1.0.0（再現性のため固定）
git submodule update --init --recursive
bash bootstrap.sh
```

## 構成

- `bootstrap.sh` — エントリ。booch を source し、custom job + 提供ジョブを並列実行する
- `jobs/` — 自分用の custom job（個人固有処理はここに置く）
- `config/` — symlink で `$HOME` 配下へ配置する設定ファイルの実体
- `vendor/booch` — booch 本体（git submodule）
READMETPL

  echo ""
  echo "雛形を生成しました: $dir"
  echo "次の手順:"
  echo "  cd $dir"
  echo "  git init && git submodule add https://github.com/kan/booch vendor/booch"
  echo "  bash bootstrap.sh"
}
