#!/usr/bin/env bash
# 現実的なブートストラップ例。booch の提供ジョブ（go / delta / codex / aws / circleci）を
# 組み合わせ、sudo を事前キャッシュしてから並列導入する。実際にツールを導入する（network +
# sudo を使う）ため、自分の環境で動かすときの雛形としてコピーして使う。CI では実行しない。
#
# 個人固有・業務固有の処理（symlink 配置・トークン・特定リポジトリの pull 等）は booch に
# 持ち込まず、利用側で足す（custom-job.sh / lib-helpers.sh を参照）。
#
# 実行: bash examples/bootstrap.sh

# job_* は runner が bash -c 経由で間接実行するため shellcheck には到達不能に見える。
# shellcheck disable=SC2317
set -uo pipefail

BOOCH_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export BOOCH_ROOT
source "$BOOCH_ROOT/lib/runner.sh"
# 提供ジョブが依存する lib（各ジョブ先頭の「依存」を参照）をまとめて source する。
source "$BOOCH_ROOT/lib/arch.sh"
source "$BOOCH_ROOT/lib/github.sh"
source "$BOOCH_ROOT/lib/verify.sh"
source "$BOOCH_ROOT/lib/sudo.sh"
source "$BOOCH_ROOT/jobs/go.sh"
source "$BOOCH_ROOT/jobs/delta.sh"
source "$BOOCH_ROOT/jobs/codex.sh"
source "$BOOCH_ROOT/jobs/aws.sh"
source "$BOOCH_ROOT/jobs/circleci.sh"

booch_runner_init

# go ツールチェイン導入後に go install で入れたいモジュールがあれば export で渡す（任意）。
# ジョブは別プロセスで動くため、非 export のグローバルは見えない。
export BOOCH_GO_TOOLS="golang.org/x/tools/gopls"

# 多くのジョブが sudo を使う。並列実行ではパスワードプロンプトが同時に出て衝突するため、
# booch_run の前に一度だけ認証をキャッシュし、各ジョブの sudo をプロンプト無しで通す。
booch_sudo_prime || { echo "sudo 認証に失敗しました" >&2; exit 1; }
trap 'booch_sudo_stop' EXIT

# tarball 取得を含む go は timeout を長めに。ジョブ名は一意にする。
booch_job go       "Go + tools"        job_go       300
booch_job delta    "delta (git pager)" job_delta    120
booch_job codex    "Codex CLI"         job_codex    120
booch_job aws      "AWS CLI + SSM"     job_aws      180
booch_job circleci "CircleCI CLI"      job_circleci 120

booch_run
