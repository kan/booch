# booch 開発ガイド

booch は WSL2 / Ubuntu 向けの再実行可能な開発環境ブートストラップ基盤。**使い方・API
の正本は [README.md](README.md)**。この CLAUDE.md は **booch 自体を安全に修正・拡張する
ためのルールと tips** に絞る。

背景: dotfiles 系スクリプトに混在しがちな汎用ブートストラップ処理の切り出し先。公開
予定のため、個人固有・業務固有の値や前提を持ち込まない。

---

## 編集前に守る鉄則

1. **冪等性を壊さない**。再実行で壊れない・無駄に再取得しない作りを保つ。
2. **改行は LF 固定**。shebang を壊さない。
3. **公開 API は `booch_` プレフィックス、内部は `_booch_` / `_BOOCH_`**。この境界を保つ。
   `export` で別プロセス（ジョブ）へ渡る変数も公開扱いで `BOOCH_` を使う
   （`BOOCH_ROOT` / `BOOCH_RESULT_DIR` / `BOOCH_JOB`）。
4. **個人固有・業務固有を持ち込まない**。トークン・特定リポジトリ名・社内ドメインなどは
   利用側 dotfiles に置く。booch は汎用部分だけを担う。
   - **`kan/dotfiles`（作者個人の dotfiles）を一切書かない**。コード既定値・コメント・
     ドキュメント・テスト・雛形のいずれにも登場させないこと。取り込む dotfiles は利用者が
     渡すもの（`install.sh` なら `--repo` / 環境変数 `BOOCH_INSTALL_REPO`）で、既定に埋め込まない。
     例示が要るときは中立のプレースホルダ（`youraccount/dotfiles` / `<owner>/<name>`）を使う。
     issue 参照も個人 dotfiles リポジトリ（`kan/dotfiles#N`）へリンクしない。
5. **コミット・バージョン bump を勝手にやらない**。コミットメッセージは日本語。

## vendor（bash-concurrent）

- `vendor/bash-concurrent/` は upstream をそのまま vendoring してコミットしている。
  **手で編集しない**。
- 更新は `vendor/update.sh`。版を上げるときはスクリプト先頭の `BC_VERSION` / `BC_PIN` /
  `BC_SHA256` を書き換えて実行し、差分をコミットする（取得物は sha256 で検証する）。
- **bash-concurrent は nounset 非対応**（未定義変数を前提に書かれている）。runner はこの
  前提の上に立つ（下記）。

## runner.sh のアーキテクチャ（拡張時に壊しやすい点）

`concurrent` はサブシェル関数で、呼び出し時に親シェルの関数・変数を継承する。一方
**個々のジョブは `bash -c` で起動する別プロセス**で動く。ここから次の制約が出る。

- **ジョブが依存してよいのは「exported 変数」と「`declare -f` で渡る関数定義」だけ**。
  非 export のグローバルや配列はジョブから見えない。新しい状態をジョブへ渡すときは
  export するか関数経由にする。
- **timeout 有無で実行モデルを一致させてある**（どちらも `bash -c "set -e; declare -f;
  fn"`）。この一致を崩さない。崩すと shell オプションや変数継承が分岐し、同じジョブが
  timeout 指定の有無で成否が変わる。
- **失敗ジョブのサマリー行は `_booch_exec` が自動記録する**。ジョブが非 0 終了 /
  timeout kill（exit 124・137）されると `failed` 行を書き、rc を返す。ジョブ側で明示的に
  `booch_result ... failed` を書く必要はない。
- **`booch_status` は fd 3**（bash-concurrent が「現在の状態」として表示する）、
  **`booch_result` は `$BOOCH_RESULT_DIR/$NAME.result`** に追記する。
  サマリーは `$NAME` ごとに集計するため **ジョブ名は一意**でなければならない
  （`booch_job` が重複を弾く）。
- **caller のシェル状態を壊さない**。`concurrent` 実行中だけ `set +u` に退避して戻す
  （nounset 非対応への対処）。`export` した変数（`BOOCH_RESULT_DIR` /
  `CONCURRENT_LOG_DIR`）は `booch_run` 後に unset し、caller の後続プロセスへ漏らさない。
- **色は tty かつ `NO_COLOR` 未設定のときだけ**使う。パイプ・CI・ログ捕捉にエスケープを
  混入させない。
- **GNU coreutils 前提**（`readlink -f` / `timeout --foreground --kill-after` /
  `mktemp -d`）。BSD / macOS 非互換は許容（主対象は WSL2 / Ubuntu）。

## 提供ジョブ（jobs/）

`jobs/<name>.sh` は再利用可能なジョブ定義を置く場所。次の規約に従う。

- **ジョブは非対話**。booch は並列ランナー内で対話できないため、「最新と異なれば
  更新」のように人手の確認なしで完結させる。更新可否の確認は利用側（dotfiles 等）が
  ジョブ登録前に行う。
- **汎用部分だけを置く**。特定個人・特定環境でしか使わないツール（プロンプト装飾・
  特定エディタの LSP など）は持ち込まない。それらは利用側の custom job に残す。
- **命名**: 登録に渡すエントリ関数は `job_<name>`、実処理を分けた継ぎ目関数は
  `booch_<name>_*`（テストや利用側が上書きできる公開シーム）。
- **テスト容易性**: ネットワーク / sudo を伴う実処理は継ぎ目関数に切り出し、エントリ
  関数の分岐（installed / updated / current / 失敗）はスタブで検証できるようにする
  （例: `jobs/go.sh` の `booch_go_latest_version` / `booch_go_installed_version` /
  `booch_go_install`）。
- **取得物の信頼モデル**: 取得は HTTPS ＋ 公式配布元に依存する（README「セキュリティ」
  参照）。upstream がチェックサムを公開しているツールは `lib/verify.sh` で SHA256 を
  照合する（go / circleci で導入済み。展開・`sudo` 導入の前に弾く）。upstream が
  チェックサムを出していないツール（delta / codex 単体バイナリ / aws）は未検証。新規
  ジョブで upstream が `.sha256` / `checksums.txt` を出していれば `booch_verify_sha256`
  ＋ `booch_verify_pick` で照合を組み込む。残りの段階的追加は issue #1 で追う。

## ライブラリヘルパー（lib/）

`lib/<name>.sh` は、ジョブや利用側 dotfiles が source して使う補助ヘルパー。runner.sh は
そのコアで、他（apt / github / verify / fs / git / uv / claude など）も独立して source
できる。鉄則 3（`booch_` / `_booch_` の境界）・鉄則 4（個人 / 業務固有を持ち込まない）は
lib にも等しく効く。加えて:

- **各ヘルパーの使い方・依存・seam はファイル冒頭コメントを正本にする**。README には 1 行
  説明だけ置く（README＝俯瞰、header＝個別 API の分担。重複させない）。
- **公開 API は `booch help <name>` で引ける**（`lib/apidoc.sh` がヘッダと公開関数シグネチャを
  ソースから抽出して表示する。jobs/ も同様）。この出力はソース生成なので、関数を追加・変更
  したら次を守ると help がそのまま API doc になる（別途 doc をメンテしない）:
  - **ファイル冒頭ヘッダの最初の非空行を、自己完結した 1 行説明にする**（`booch help` の索引に
    出る）。
  - **公開関数の宣言に引数ヒントを付ける**（`booch_xxx() { # arg1 arg2 [opt]`）。help が
    `booch_xxx(arg1 arg2 [opt])` として表示する。内部関数（`_booch_*`）は help に出ない
    ので、公開したい関数は `booch_` プレフィックスで書く（鉄則 3 と同じ境界）。
  - 新しい lib/jobs を足せば `booch help` に自動で載る（登録簿の更新は不要）。抽出規約の
    詳細は `lib/apidoc.sh` の冒頭コメントを正本にする。
- **ネットワーク / sudo を伴う処理は seam に切り出す**（jobs/ と同じ方針）。`booch_github_fetch`
  / `booch_verify_fetch` のような副作用関数を分け、分岐ロジックをスタブで純粋にテストできる
  ようにする。

## CLI（bin/booch）と雛形（lib/scaffold.sh）

`bin/booch` は補助 CLI（`init` / `version` / `help`）で、本体はあくまで source して使うライブラリ。
`init` は `lib/scaffold.sh` の `booch_scaffold <dir>` に委譲し、利用側 dotfiles の雛形を作る。
`help` は `lib/apidoc.sh` に委譲し、引数なしでモジュール一覧、`help <name>` でモジュールの
ヘッダ + 公開関数シグネチャを表示する（上記「ライブラリヘルパー」の help 維持規約を参照）。

- **雛形は quoted heredoc（`<<'MARK'`）で書く**。`$BOOCH_ROOT` 等を生成時に展開させないため。
  生成物に個人固有・業務固有の値を埋め込まず、プレースホルダ（`<...>` / `(edit me)`）で示す。
- **生成物は冪等**。既存ファイルは上書きしない（`_booch_scaffold_write` が skip する）。
- **生成したシェルは構文妥当に保つ**。`tests/scaffold_test.sh` が生成物を `bash -n` で検証する
  ので、雛形を直したらテストで回帰を防ぐ。
- `bin/booch` は CI / 動作確認の lint 対象（`.sh` 拡張子が無いのでグロブに明示で含める）。

ルートの `install.sh` は **素の OS から booch を使う dotfiles を入れるワンライナー bootstrap**
（`curl | bash`。Windows 版は別リポジトリ kan/booch-win の `win.ps1`）。

- **自己完結に保つ**。booch がまだ無い状態で走るため、booch の lib を source できない（gh の
  apt repo 追加なども install.sh 内にインライン）。冪等（無ければ入れる / 既存なら更新）。
- **副作用は seam に切り出す**（`booch_install_apt` / `_gh` / `_git` / `_exec`）。テストは
  `BOOCH_INSTALL_NO_RUN=1` で source し、seam をスタブして network/sudo/実行なしで分岐を検証する
  （`tests/install_test.sh`）。末尾の `main` 実行はこの env で抑止される。
- **clean 環境での実地スモークは未実施**（`curl|bash` 下の gh auth の tty 取り回し等）。実機検証は
  別途。`install.sh` も lint グロブ対象。

## 動作確認

CI（`ci.yml`）と同じ一式をローカルでも回す。対象は全ファイル（`bin/booch` `install.sh`
`lib/*.sh` `jobs/*.sh` `vendor/update.sh` `examples/*.sh` `tests/*.sh`）で、CI のグロブと
一致させる。

```bash
bash -n bin/booch install.sh lib/*.sh jobs/*.sh vendor/update.sh examples/*.sh tests/*.sh      # 構文チェック
shellcheck -x bin/booch install.sh lib/*.sh jobs/*.sh vendor/update.sh examples/*.sh tests/*.sh
bash tests/run.sh                                          # ユニットテスト
bash tests/smoke.sh                                        # ランナースモーク（失敗/timeout 込み）
```

## テスト

`tests/` に外部依存のないユニットテストを置く。`bash tests/run.sh` でローカル実行、
GitHub Actions（`.github/workflows/ci.yml`）で push / pull request ごとに同じ一式
（構文チェック / shellcheck / ユニットテスト / ランナースモーク）を回す。

- `tests/lib.sh`: 最小テストフレームワーク。`test_*` 関数をサブシェル + `set -e` で
  隔離実行し集計する。
- `tests/*_test.sh`: 各対象のテスト。runner はフェイク job で駆動し、`update.sh` は
  curl を shim で差し替えてネットワーク非依存にする。`tests/run.sh` は `*_test.sh` だけを
  集めて実行するため、スモーク（`smoke.sh`）はユニット実行に混ざらない。
- テストはなるべく **code-review で見つけた不具合の回帰ガード**として書く。
- `tests/smoke.sh` はランナーのエンドツーエンド・スモークであり、ユニットテストの代替では
  ない。利用者向けの使い方サンプルは `examples/`（実際にツールを導入する現実例を含む）。

## セキュリティ施策（CI / リポジトリ設定）

依存パッケージを持たない Bash 製に合わせた施策を敷いている（採否一覧は README「リポジトリ
のセキュリティ施策」、報告手順は SECURITY.md）。拡張時の留意点だけ記す。

- **ShellCheck がゲート兼 Code scanning ソース**。`ci.yml` の `shellcheck -x`（全ファイル）が
  失敗ゲート、`security.yml`（`differential-shellcheck`）が同じ ShellCheck 結果を SARIF で
  Security タブへ上げる。新しい `.sh` を足せば追加設定なしで両方に乗る。指摘は disable で
  握り潰さず原則直す。
- **ワークフローの actions は Dependabot が追従する**（`.github/dependabot.yml`、
  github-actions エコシステム）。新しいワークフローを足しても同じ設定で追従対象になる。
  `vendor/bash-concurrent` は Dependabot 対象外で `vendor/update.sh`（sha256 ピン）で更新する。
- **CodeQL は使わない**（Bash 非対応）。Code scanning は上記 ShellCheck → SARIF で代替する。

## リリース手順

バージョンの正本はルートの `VERSION`（SemVer 1 行）。`booch version`（`lib/runner.sh` の
`booch_version`）と git タグ `v<...>` をこれに一致させる。リリースは GitHub Releases
（タグ + ノート）で行い、配布は clone / submodule（vendor 同梱で clone は自己完結。tarball は
付けない）。消費側は submodule をリリースタグに pin する想定（README「booch 本体の取り込み」）。

再現手順（**バージョン bump は勝手にやらない**。指示があってから）:

1. `VERSION` を上げる（SemVer）。`booch version` が新版を返すことを確認
2. `CHANGELOG.md` の `[Unreleased]` を新バージョンの節へ繰り上げ、日付と比較リンクを付ける
3. 変更をコミット（日本語メッセージ。bump とノートを含む）
4. タグを打って push: `git tag v1.1.0 && git push origin v1.1.0`
5. リリース作成: `gh release create v1.1.0 --title v1.1.0 --notes "<CHANGELOG の当該節>"`
6. README のバッヂ／取り込み手順のタグ（`checkout v1.1.0`）が新版を指すか確認

## ドキュメントの保守

API・構成・前提を変えたら **README.md も更新する**。使い方の説明は README に寄せ、本
ファイルには重複させない（拡張ルールの正本は CLAUDE.md、使い方の正本は README）。
