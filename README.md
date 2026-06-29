# booch

[![CI](https://github.com/kan/booch/actions/workflows/ci.yml/badge.svg)](https://github.com/kan/booch/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/kan/booch?sort=semver)](https://github.com/kan/booch/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash&logoColor=white)
![Platform: WSL2 / Ubuntu](https://img.shields.io/badge/platform-WSL2%20%2F%20Ubuntu-E95420?logo=ubuntu&logoColor=white)

WSL2 / Ubuntu 向けの、再実行可能な開発環境ブートストラップ基盤（Bash 製）。

ツールのインストール定義（job）を並列実行し、進捗と結果をまとめて表示する。
dotfiles スクリプトに混ざりがちな汎用的な導入や更新の処理を切り出して共有することを
狙う。個人固有の設定（symlink、トークン、プロジェクトの pull など）は利用側の
dotfiles に残し、booch は汎用部分だけを担う。

並列ジョブランナーのコアに加え、導入ヘルパー（apt / github / verify / uv / claude など）と
提供ジョブ（go / delta / codex / aws / circleci）、利用側 dotfiles の雛形生成（`booch init`）を
備える。

## クイックスタート（ワンライナー）

素の WSL2 / Ubuntu から、booch を使う dotfiles を入れて setup を起動するところまでを 1 コマンドで:

```bash
curl -fsSL https://raw.githubusercontent.com/kan/booch/v1.0.1/install.sh | bash
# 配置先や取り込む repo を指定する場合（bash -s -- で後続をスクリプトへ）:
curl -fsSL https://raw.githubusercontent.com/kan/booch/v1.0.1/install.sh | bash -s -- \
    --dir "$HOME/dotfiles" --repo <owner>/<dotfiles>
```

`install.sh` は git / gh の確保 → gh 認証 → dotfiles の clone → submodule 初期化（または
booch の sibling clone）→ dotfiles の setup 起動を冪等に行う。ライブラリとして直接使う場合や
雛形をゼロから作る場合は下記「使い方」「利用側 dotfiles の作り方」を参照する。

## 構成

```
booch/
├── install.sh                    # ワンライナー bootstrap（素の OS → dotfiles setup 起動）
├── bin/
│   └── booch                     # CLI（init: dotfiles 雛形の生成 / version）
├── lib/
│   ├── runner.sh                 # 並列ジョブランナー（bash-concurrent 上に構築）
│   ├── color.sh                  # 色（ANSI）の共通定義（tty/NO_COLOR gate）
│   ├── arch.sh                   # アーキテクチャ名の解決（dpkg 系 / rust 系）
│   ├── os.sh                     # OS 検出（os-release → BOOCH_OS_*）
│   ├── apt.sh                    # APT リポジトリ追加・コードネーム解決
│   ├── doctor.sh                 # 診断レポートのフレーム（行描画・バージョン比較・集計）
│   ├── github.sh                 # GitHub Releases（最新タグ取得・資産ダウンロード）
│   ├── verify.sh                 # 取得物の SHA256 検証（upstream のチェックサムと照合）
│   ├── uv.sh                     # uv 本体と uv tool の冪等な導入 / 更新
│   ├── claude.sh                 # Claude Code 本体 / marketplace / plugin の冪等な導入・更新
│   ├── npm.sh                    # ローカル npm プロジェクト同期 / グローバル install
│   ├── confirm.sh                # 更新確認のフレーム（登録前の y/N 判断・tty プロンプト）
│   ├── sudo.sh                   # 並列ジョブ向け sudo 事前キャッシュ + キープアライブ
│   ├── fs.sh                     # symlink 配置 / TOML キーの冪等更新
│   ├── git.sh                    # 自己更新（pull→再exec）/ 複数リポジトリの ff-only pull
│   ├── cleanup.sh                # cleanup フレーム（コマンド実行表示 / 解放量 / docker 安全 prune）
│   ├── wsl.sh                    # WSL 判定 / binfmt interop 診断
│   ├── docker.sh                 # docker post-install（グループ / デーモン / 再ログイン案内）
│   └── scaffold.sh               # 利用側 dotfiles 雛形の生成（booch init の実体）
├── jobs/
│   ├── go.sh                     # 提供ジョブ: Go ツールチェインの導入 / 更新
│   ├── delta.sh                  # 提供ジョブ: delta (git pager) の導入 / 更新
│   ├── codex.sh                  # 提供ジョブ: Codex CLI の導入 / 更新
│   ├── aws.sh                    # 提供ジョブ: AWS CLI v2 + Session Manager Plugin
│   └── circleci.sh               # 提供ジョブ: CircleCI CLI の導入 / 更新
├── vendor/
│   ├── bash-concurrent/          # 並列実行ライブラリ（MIT, vendoring してコミット）
│   └── update.sh                 # vendor 更新スクリプト（メンテ用）
├── tests/                        # ユニットテスト（依存なし）+ runner スモーク（smoke.sh）
├── examples/                     # 利用側向けの使い方サンプル
│   ├── README.md                 # サンプルの読む順番
│   ├── custom-job.sh             # 最小: booch を source して custom job を登録
│   ├── bootstrap.sh              # 現実例: 提供ジョブを sudo 事前キャッシュ付きで一括導入
│   └── lib-helpers.sh            # fs / confirm / sudo ヘルパーの小サンプル
├── VERSION                       # SemVer（booch version / git タグ v<...> と一致）
└── CHANGELOG.md                  # 変更履歴（Keep a Changelog）
```

## 前提

- bash >= 4.2（bash-concurrent が `declare -g` を要求する）
- GNU coreutils（`readlink -f` / `timeout --foreground --kill-after` / `mktemp -d`）、
  および bash-concurrent が使う `cat` `cp` `date` `mkdir` `mkfifo` `mktemp` `mv`
  `sed` `tail` `tput`

WSL2 / Ubuntu を主対象とする。BSD / macOS の `readlink` と `timeout` はオプションが
非互換のため、そのままでは動かない。

一部のライブラリは追加で次を使う: `lib/github.sh` は `curl` と `jq`、`lib/verify.sh` は
`curl` と `sha256sum`、`lib/apt.sh` は `curl` / `gpg` / `dpkg` / `sudo`、`jobs/` の各
ジョブは対象ツールの取得に `curl` 等。

## 使い方

[bash-concurrent](https://github.com/themattrix/bash-concurrent) を土台に、
ジョブ単位のタイムアウトと実行後サマリー（installed / updated / current / migrated /
failed）を加えた薄い層が `lib/runner.sh` である。スピナー、経過秒、失敗ログの表示、
終了コードは bash-concurrent が担当する。

`runner.sh` を source し、ジョブを関数として登録して並列実行する。

```bash
export BOOCH_ROOT=/path/to/booch
source "$BOOCH_ROOT/lib/runner.sh"
booch_runner_init

job_go() {
  booch_status "downloading..."        # 実行中の 1 行ステータスを更新する
  # ... 導入処理 ...
  booch_result "Go" updated 1.22 1.23   # サマリーに 1 行を記録する
}

booch_job go "Go + tools" job_go 120    # name label fn [timeout秒]
booch_run                                # 並列実行してサマリーを表示する
```

### API

| 関数 | 役割 |
|---|---|
| `booch_runner_init` | vendor を読み込み、結果記録用の領域を用意する |
| `booch_job NAME LABEL FN [TIMEOUT]` | ジョブを登録する。`NAME` は一意、`TIMEOUT` 秒は省略時 120、`0` で無効 |
| `booch_run` | 登録済みジョブを並列実行し、サマリーを表示する |
| `booch_status MSG` | ジョブ関数内から実行中の 1 行ステータスを更新する |
| `booch_result TOOL STATUS [OLD] [NEW]` | ジョブ関数内からサマリー行を記録する（`STATUS`: installed / updated / current / migrated / failed） |

ジョブ関数は exported 変数と関数定義だけに依存できる（別プロセスで実行されるため）。
詳細は `CLAUDE.md` を参照。

### ライブラリヘルパー（lib/）

`lib/` には、ジョブや利用側 dotfiles から source して使う補助ヘルパーを置く（APT
リポジトリ追加・GitHub Releases 取得・SHA256 検証・uv / Claude の冪等導入・symlink 配置
など）。各ヘルパーは公開関数を `booch_` プレフィックスで提供し、使い方・依存・テスト用の
継ぎ目（seam）をファイル冒頭のコメントに記す。ネットワーク / sudo を伴う処理は seam に
切り出してあり、スタブで差し替えてユニットテストできる。runner.sh 以外のヘルパーは独立
して source でき、必要なものだけ使えばよい。

### 提供ジョブ

`jobs/` の定義済みジョブは source して登録するだけで使える。ジョブは非対話で、更新
可否を人に確認したい場合は呼び出し側が登録前に判断する。

```bash
source "$BOOCH_ROOT/jobs/go.sh"
booch_job go "Go" job_go 300            # 未導入なら導入、最新と異なれば更新
```

### サンプル

利用側 dotfiles からどう組むかは `examples/` のサンプルを参照する（読む順番は
[examples/README.md](examples/README.md)）。

| サンプル | 狙い |
|---|---|
| `examples/custom-job.sh` | booch を source して自分用の custom job を登録する最小例 |
| `examples/bootstrap.sh` | 提供ジョブ（go / delta / codex / aws / circleci）を sudo 事前キャッシュ付きで一括導入する現実例 |
| `examples/lib-helpers.sh` | `fs.sh` の symlink / TOML 更新、`confirm.sh` の更新確認、`sudo.sh` の事前キャッシュの使い方 |

サンプルは実際にツールを導入する（network + sudo）ものを含むため、コピーして自分の環境に
合わせる出発点として使う。

## 利用側 dotfiles の作り方

booch は汎用基盤で、個人固有の設定（symlink・トークン・custom job）は利用側 dotfiles に
置く。その出発点は `booch init` で雛形を生成できる（冪等。既存ファイルは上書きしない）。

```bash
bin/booch init ~/dotfiles
```

生成される雛形:

| ファイル | 役割 |
|---|---|
| `bootstrap.sh` | エントリ。booch を source し、custom job + 提供ジョブを並列実行する |
| `jobs/example.sh` | custom job のサンプル（個人固有処理はここに置く） |
| `config/README.md` | symlink で `$HOME` 配下へ配置する設定ファイルの置き場 |
| `.gitignore` / `README.md` | dotfiles リポジトリのひな形 |

雛形には個人固有・業務固有の値を埋め込まず、プレースホルダで示す。

### booch 本体の取り込み（推奨: git submodule + リリースタグ pin）

再現性のため、booch は **git submodule で取り込み、リリースタグに固定**するのを推奨する。
更新するときは submodule を新しいタグへ進める（いつ・どの版に上げたかが履歴に残る）。

```bash
cd ~/dotfiles
git init
git submodule add https://github.com/kan/booch vendor/booch
git -C vendor/booch checkout v1.0.1   # リリースタグに固定（更新時はタグを上げる）
git submodule update --init --recursive
bash bootstrap.sh
```

`bootstrap.sh` は `BOOCH_ROOT` を `vendor/booch` に既定で向ける。別の場所に置いた clone を
使いたい場合（例: `~/dotfiles` の隣に `~/booch` を clone して最新を追従する運用）は
`BOOCH_ROOT` を上書きすればよい。取り込んだ版は `booch version` で確認できる。

個々のパターン（custom job・symlink 配置・提供ジョブの組み合わせ）を単体で見たいときは
`examples/`（上記「サンプル」）を参照する。

## テスト

外部依存のないユニットテストを `tests/` に置く。

```bash
bash tests/run.sh        # ユニットテスト
bash tests/smoke.sh      # ランナーのスモーク（失敗ジョブ・timeout を含むため rc=1 が正常）
```

`tests/smoke.sh` はランナーが正常終了・ステータス更新・サマリー各種・失敗ログ表示・
タイムアウトをひととおり正しく扱うかを確認するエンドツーエンドのスモークで、ユニット
テストの代替ではない。GitHub Actions（`.github/workflows/ci.yml`）が push と pull request
ごとに、構文チェック・shellcheck・ユニットテスト・スモークを実行する。

## セキュリティ（取得物の信頼モデル）

提供ジョブは各ツールを HTTPS 経由で公式配布元（go.dev / GitHub Releases /
awscli.amazonaws.com / astral.sh / claude.ai 等）から取得して導入する。転送の完全性と
配布元の真正性は HTTPS に依存し、rustup / nvm / uv 等の公式インストーラと同水準の信頼
モデルである。

「最新版を入れる」ジョブはバージョンが事前に未知のため、固定 SHA256 ピン（vendor の
bash-concurrent で採用）は適用できない。代わりに **upstream が実行時に公開するチェック
サムを引いて照合する**（`lib/verify.sh`）。upstream がチェックサムを出しているツールから
段階的に検証を追加している（[#1](https://github.com/kan/booch/issues/1)）。

| ツール | 検証 | 照合元 |
|---|---|---|
| Go | ✅ SHA256 | `https://dl.google.com/go/<tarball>.sha256` |
| CircleCI CLI | ✅ SHA256 | リリースの `circleci-cli_<ver>_checksums.txt` |
| delta | ❌ 未検証 | upstream がチェックサムファイルを公開していない |
| Codex CLI | ❌ 未検証 | 単体バイナリは sigstore のみで簡易チェックサムなし |
| AWS CLI / SSM Plugin | ❌ 未検証 | GPG 署名（別機構）。導入は HTTPS の真正性に依存 |
| uv / Claude（インストーラ） | ❌ 未検証 | `curl \| sh` 系。署名提供なし。HTTPS の真正性に依存 |

検証付きツールは、取得物のハッシュが期待値と一致しなければ展開・`sudo` 導入へ進まず失敗
する。未検証ツールは引き続き「HTTPS ＋ 配布元の真正性」に依存する（rustup / nvm / uv 等
の公式インストーラと同水準）。

## リポジトリのセキュリティ施策

booch は依存パッケージを持たない Bash 製のため、一般的な依存スキャン（Dependabot の
gomod / npm、CodeQL 等）はそのまま適用できない。構成に合わせて次を採否した。脆弱性の
報告手順は [SECURITY.md](SECURITY.md) を参照。

| 施策 | 採否 | 内容 / 理由 |
|---|---|---|
| Dependabot（github-actions） | ✅ 採用 | `.github/dependabot.yml`。ワークフローが使う Actions のバージョンを週次で追従 |
| Dependabot alerts / security updates | ✅ 採用 | 既知脆弱性のある Actions を検知・自動更新（リポジトリ設定で有効化） |
| Dependabot（gomod / npm 等） | — 非該当 | package manifest を持たないため対象外 |
| Secret scanning / Push protection | ✅ 採用 | トークン等の混入を検出・ブロック（GitHub 標準・有効） |
| Code scanning（CodeQL） | — 非該当 | CodeQL は Bash を直接サポートしない |
| Code scanning（ShellCheck → SARIF） | ✅ 採用 | `.github/workflows/security.yml`。CodeQL の代替として ShellCheck の結果を Security タブへ連携。失敗ゲートは CI の `shellcheck -x` が担う |
| vendor/bash-concurrent の追従 | ⚙️ 手動 | Dependabot 対象外。`vendor/update.sh`（sha256 ピン）で更新する |

## vendor の更新

bash-concurrent は vendor 方式でリポジトリにコミットしている。版を上げるときは
`vendor/update.sh` 内の PIN / SHA256 を書き換えて実行し、差分をコミットする。取得した
ファイルは sha256 で検証する。

## ライセンス

MIT（`LICENSE`）。`vendor/bash-concurrent/` は upstream の MIT ライセンス
（`vendor/bash-concurrent/LICENSE`）に従う。
