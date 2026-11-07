# booch 開発ガイド

booch は WSL2 / Ubuntu 向けの再実行可能な開発環境ブートストラップ基盤。**使い方と API
の正本は [README.md](README.md)**。この CLAUDE.md は **booch 自体を安全に修正し拡張する
ためのルールと tips** に絞る。

背景: dotfiles 系スクリプトに混在しがちな汎用ブートストラップ処理の切り出し先。公開
リポジトリのため、個人固有や業務固有の値と前提を持ち込まない。

---

## 編集前に守る鉄則

1. **冪等性を壊さない**。再実行で壊れず、無駄に再取得しない作りを保つ。
2. **改行は LF 固定**。shebang を壊さない。
3. **公開 API は `booch_` プレフィックス、内部は `_booch_` / `_BOOCH_`**。この境界を保つ。
   `export` で別プロセス（ジョブ）へ渡る変数も公開扱いで `BOOCH_` を使う
   （`BOOCH_ROOT` / `BOOCH_RESULT_DIR` / `BOOCH_JOB`）。
4. **個人固有や業務固有のものを持ち込まない**。トークン、特定リポジトリ名、社内ドメインなどは
   利用側 dotfiles に置く。booch は汎用部分だけを担う。
   - **`kan/dotfiles`（作者個人の dotfiles）を一切書かない**。コード既定値、コメント、
     ドキュメント、テスト、雛形のいずれにも登場させないこと。取り込む dotfiles は利用者が
     渡すもの（`install.sh` なら `--repo` / 環境変数 `BOOCH_INSTALL_REPO`）で、既定に埋め込まない。
     例示が要るときは中立のプレースホルダ（`youraccount/dotfiles` / `<owner>/<name>`）を使う。
     issue 参照も個人 dotfiles リポジトリ（`kan/dotfiles#N`）へリンクしない。
5. **コミットとバージョン bump を勝手にやらない**。コミットメッセージは日本語。

## vendor（bash-concurrent）

- `vendor/bash-concurrent/` は upstream をそのまま vendoring してコミットしている。
  **手で編集しない**。
- 更新は `vendor/update.sh`。版を上げるときはスクリプト先頭の `BC_VERSION` / `BC_PIN` /
  `BC_SHA256` を書き換えて実行し、差分をコミットする（取得物は sha256 で検証する）。
- **bash-concurrent は nounset 非対応**（未定義変数を前提に書かれている）。runner はこの
  前提の上に立つ（下記）。

## runner.sh のアーキテクチャ（拡張時に壊しやすい点）

`concurrent` はサブシェル関数で、呼び出し時に親シェルの関数と変数を継承する。一方
**個々のジョブは `bash` で起動する別プロセス**で動く（`_booch_exec` が関数定義を一時
スクリプトへ書き出して実行する）。ここから次の制約が出る。

- **ジョブが依存してよいのは「exported 変数」と「`declare -f` で渡る関数定義」だけ**。
  非 export のグローバルや配列はジョブから見えない。新しい状態をジョブへ渡すときは
  export するか関数経由にする。
- **timeout 有無で実行モデルを一致させてある**（どちらも `set -e; declare -f; fn` を一時
  ファイルへ書き出し、`bash <file>` で実行する。timeout ありは `timeout ... bash <file>`）。
  この一致を崩さない。崩すと shell オプションや変数継承が分岐し、同じジョブが
  timeout 指定の有無で成否が変わる。
- **関数定義を `bash -c "<inner>"` の引数で渡す形に戻さない**。1 引数の長さ上限
  （MAX_ARG_STRLEN = 128KiB）を超えると execve が E2BIG で失敗し、lib と jobs の関数が
  増えると inner はこの上限に届く。ファイル実行にはこの上限が無い。
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
- **色は tty かつ `NO_COLOR` 未設定のときだけ**使う。パイプ、CI、ログ捕捉にエスケープを
  混入させない。
- **GNU coreutils 前提**（`readlink -f` / `timeout --foreground --kill-after` /
  `mktemp -d`）。BSD / macOS 非互換は許容（主対象は WSL2 / Ubuntu）。

## 提供ジョブ（jobs/）

`jobs/<name>.sh` は再利用可能なジョブ定義を置く場所。次の規約に従う。

- **ジョブは非対話**。booch は並列ランナー内で対話できないため、「最新と異なれば
  更新」のように人手の確認なしで完結させる。更新可否の確認は利用側（dotfiles 等）が
  ジョブ登録前に行う。
- **汎用部分だけを置く**。特定の個人や環境でしか使わないツール（プロンプト装飾、
  特定エディタの LSP など）は持ち込まない。それらは利用側の custom job に残す。
- 命名: 登録に渡すエントリ関数は `job_<name>`、実処理を分けた継ぎ目関数は
  `booch_<name>_*`（テストや利用側が上書きできる公開シーム）。
- テスト容易性: ネットワーク / sudo を伴う実処理は継ぎ目関数に切り出す。エントリ
  関数の分岐（installed / updated / current / 失敗）はスタブで検証できるようにする
  （例: `jobs/go.sh` の `booch_go_latest_version` / `booch_go_installed_version` /
  `booch_go_install`）。
- 取得物の信頼モデル: 取得は HTTPS ＋ 公式配布元に依存する（README「セキュリティ」
  参照）。upstream がチェックサムを公開しているツールは `lib/verify.sh` で SHA256 を
  照合する（go / circleci / starship で導入済み。展開や `sudo` での導入の前に弾く）。codex は公式
  インストーラ自身がパッケージの SHA256 を照合する。upstream が
  チェックサムを出していない GitHub Releases の資産（delta / shellcheck）は、Releases API が資産に付ける
  digest で照合する（`booch_github_verify_asset`）。aws は未検証。新規
  ジョブで upstream が `.sha256` / `checksums.txt` を出していれば `booch_verify_sha256`
  ＋ `booch_verify_pick` で照合を組み込む（starship のようにファイル名を含まない per-asset の
  `.sha256` は `booch_verify_pick` を通さず先頭のハッシュを渡す）。チェックサムが無く GitHub Releases から
  資産を取るジョブは、ダウンロード後に `booch_github_verify_asset` で照合する（delta / shellcheck と同じ）。

## ライブラリヘルパー（lib/）

`lib/<name>.sh` は、ジョブや利用側 dotfiles が source して使う補助ヘルパー。runner.sh は
そのコアで、他（apt / github / verify / fs / git / uv / claude など）も独立して source
できる。鉄則 3（`booch_` / `_booch_` の境界）と鉄則 4（個人 / 業務固有を持ち込まない）は
lib にも同じく適用する。加えて:

- **各ヘルパーの使い方、依存、seam はファイル冒頭コメントを正本にする**。README には 1 行
  説明だけ置く（README＝俯瞰、header＝個別 API の分担。重複させない）。
- **公開 API は `booch help <name>` で引ける**（`lib/apidoc.sh` がヘッダと公開関数シグネチャを
  ソースから抽出して表示する。jobs/ も同様）。この出力はソース生成なので、関数を追加や変更
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
  生成物に個人固有や業務固有の値を埋め込まず、プレースホルダ（`<...>` / `(edit me)`）で示す。
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
node scripts/tagpr/verify-subtree.mjs                      # scripts/tagpr/ と tagpr.yml の SHA の一致（HEAD を見るので commit 後に回す）
```

`scripts/tagpr/` は `.mjs` だけで `.sh` を含まないので、構文チェックと shellcheck のグロブには入れない。

## テスト

`tests/` に外部依存のないユニットテストを置く。`bash tests/run.sh` でローカル実行、
GitHub Actions（`.github/workflows/ci.yml`）で push / pull request ごとに同じ一式
（構文チェック / shellcheck / ユニットテスト / ランナースモーク）と、`scripts/tagpr/` の照合
（`tagpr-subtree` ジョブ）を回す。

- `tests/lib.sh`: 最小テストフレームワーク。`test_*` 関数をサブシェル + `set -e` で
  隔離実行し集計する。
- `tests/*_test.sh`: 各対象のテスト。runner はフェイク job で駆動し、`update.sh` は
  curl を shim で差し替えてネットワーク非依存にする。`tests/run.sh` は `*_test.sh` だけを
  集めて実行するため、スモーク（`smoke.sh`）はユニット実行に含まれない。
- テストはなるべく **code-review で見つけた不具合の回帰ガード**として書く。
- `tests/smoke.sh` はランナーのエンドツーエンドのスモークであり、ユニットテストの代替では
  ない。利用者向けの使い方サンプルは `examples/`（実際にツールを導入する現実例を含む）。

## セキュリティ施策（CI / リポジトリ設定）

依存パッケージを持たない Bash 製に合わせた施策を敷いている（採否一覧は README「リポジトリ
のセキュリティ施策」、報告手順は SECURITY.md）。拡張時の留意点だけ記す。

- **ShellCheck がゲート兼 Code scanning ソース**。`ci.yml` の `shellcheck -x`（全ファイル）が
  失敗ゲート、`security.yml`（`differential-shellcheck`）が ShellCheck の結果を SARIF で
  Security タブへ上げる。新しい `.sh` を足せば追加設定なしで両方に乗る。指摘は disable で
  握り潰さず原則直す（間接呼び出しのスタブに出る SC2317 / SC2329 のような偽陽性だけ、理由を
  書いてファイル単位で抑制する）。
- **ShellCheck の版は手元と CI で揃える**。ランナー同梱版はイメージの版に張り付くため、
  `ci.yml` は `jobs/shellcheck.sh` で最新版を導入してから検査する（`security.yml` の
  differential-shellcheck はコンテナ同梱の shellcheck を使う）。版がずれると「ローカルで赤、
  CI で緑」が起きるので、新しい検査が増えて手元が赤くなったら直す方を選ぶ。
- **ワークフローの actions は `.github/workflows/actions.lock`（workflow lockfile）で commit に固定し、
  Dependabot が追従する**（`.github/dependabot.yml`、github-actions エコシステム）。lockfile の生成と更新は
  GitHub CLI の拡張 `gh actions-lock`（`gh extension install github/gh-actions-lock`）で行い、**手で編集しない**。
  - **`uses:` には SHA を書かず、完全な版のタグ（`@v7.0.1`）で書く**。commit の SHA は lockfile が持つ。
    SHA や可動タグ（`@v5`）で書いても、`gh actions-lock` が生成時に完全な版のタグへ書き換える。可動タグのままだとタグの指す中身が変わっても PR が
    出ないため、パッチ更新も差分としてレビューできるようにする。
  - **`uses:` を足す・消す・変える、またはワークフローを足したら `gh actions-lock` を流し直し、lockfile も
    同じコミットに入れる**。載っていない参照があると、そのワークフローはジョブが始まる前に startup_failure で
    止まる。コミット前の確認は `gh actions-lock --verify`（書き込まずに検査する。ネットワークに出る）。CI でも
    `verify-lockfile.yml` が PR と main への push のたびに同じ検査を回す（拡張の版は `--pin` で固定してあり、
    Dependabot は上げない。lockfile の形式が上がって落ちたら、手元の拡張と同じ版に上げる）。
  - 版の更新は Dependabot が lockfile ごと PR で運ぶ（github-actions の更新 PR が該当エントリも作り直す）。
  - lockfile が固定するのは action の commit だけで、action が使うコンテナイメージは対象外
    （`differential-shellcheck` のイメージは digest で固定されておらず、`gh actions-lock` が警告を出す）。
  - `vendor/bash-concurrent` は Dependabot 対象外で `vendor/update.sh`（sha256 ピン）で更新する。
- **CodeQL は使わない**（Bash 非対応）。Code scanning は上記 ShellCheck → SARIF で代替する。

## 変更の入れ方（PR 運用）

**変更は main へ直接 push せず、ブランチを切って PR で入れる**（ルートに `.tagpr` がある）。
tagpr はマージされた PR からリリース PR を組み立てるので、main へ直接 push した変更はリリースの
組み立てから漏れる。ブランチの push、PR の作成、マージはユーザーの承認を得てから行う。

- **利用者に届く変更は、その PR で `CHANGELOG.md` の `## [Unreleased]` に行を足す**。この節が
  そのまま Release の本文になる。節の中は小見出し（`### Added` / `### Changed` / `### Fixed` など）で
  分ける。書式の制約（節の中のリンクはインラインで書く、参照リンクを使わない、
  `[Unreleased]` の compare リンクを置かない、など）は tagpr-scripts の README
  「What the CHANGELOG has to look like」を正本にする。
- **機能の追加（minor を上げる変更）は、その PR に `enhancement` ラベルを付ける**（`.tagpr` の
  `minorLabels`）。付けなければ tagpr は patch を提案する。
- **`VERSION` と CHANGELOG の版の節は手で書かない**。リリース PR で tagpr と
  `scripts/tagpr/release-prepare.mjs` が書く。

## リリース手順

バージョンの正本はルートの `VERSION`（SemVer 1 行）。`booch version`（`lib/runner.sh` の
`booch_version`）と git タグ `v<...>` をこれに一致させる。リリースは GitHub Releases
（タグ + ノート）で行い、配布は clone / submodule（vendor 同梱で clone は自己完結。tarball は
付けない）。消費側は submodule をリリースタグに pin する想定（README「booch 本体の取り込み」）。

リリースは [tagpr](https://github.com/Songmu/tagpr) で行う。処理は
[kan/tagpr-scripts](https://github.com/kan/tagpr-scripts) の共通の workflow とスクリプトで、
`scripts/tagpr/` に `git subtree` で取り込んでいる。各段の挙動と、run が失敗したときの扱いの
正本は tagpr-scripts の README「The tagpr workflow」。

1. main へのマージのたびに `.github/workflows/tagpr.yml` がリリース PR を作り直す。`VERSION` と
   CHANGELOG の版の節はリリース PR が書く
2. 版は既定で patch。`enhancement` の PR がマージされていれば minor。リリース PR に
   `tagpr:minor` / `tagpr:major` を付けても上げられる（`tagpr-label.yml` がラベルの変化で
   リリース PR を作り直す）
3. **リリース PR のマージがリリースの実行にあたる。バージョン bump と同じく、ユーザーの指示が
   あってからマージする**。tagpr の run が赤のリリース PR はマージしない。リリース PR は
   GITHUB_TOKEN で作られるので `ci.yml` などの PR の CI は走らない（検査結果が付かないのは正常）。
   リリース PR が変えるのは `VERSION` と `CHANGELOG.md` だけで、検査は tagpr の run と
   `release.yml` が担う
4. マージ後の run がタグを打ち、そのタグで `release.yml` を起動する。`release.yml` はタグを検査し
   （下記）、CHANGELOG の節を本文にして GitHub Release を作る

プレリリース（`vX.Y.Z-rc.1`）は main に手で annotated のタグを打って push する。`release.yml` の
`push: tags` が動き、本文は `## [Unreleased]` になる。`VERSION` は前の版のままにする（rc に
書き換えると tagpr が版を書き換えられない）。`release.yml` はプレリリースのタグでは `VERSION` との
一致を検査しない。

README は版番号を固定で書かない（Release バッヂはリリースから自動で出し、取り込み手順は
`vX.Y.Z` のプレースホルダ）。リリースのたびに README を書き換える必要は無いので、固定の版番号を
README に書き足さない。

**タグは annotated で打つ**。lightweight タグは `git describe`（`--tags`
無し）から無視され、利用側が `git submodule status` / `git describe` で pin 先を確認したときに
1 つ前のリリースが表示される。tagpr のタグは共通の workflow が annotated にする（tagpr-scripts の
README「The tagpr workflow」）。手で打つタグは `git tag -a` で打つ。
過去のタグは lightweight / annotated が混在しているが、打ち直さず
今後のタグだけを揃える。配布済みのタグを貼り直しても、手元に古いタグを持つ clone は fetch で
更新されず、種別が食い違うためである（過去版を pin して確認する側は `git describe --tags`
を使えば混在の影響を受けない）。この前提（annotated であることと、`VERSION` とタグ名の一致）は
`.github/workflows/release.yml` が Release を作る前に検査するので、打ち間違えれば赤で気付き、
Release も作られない。

CHANGELOG の末尾のリンクは、v1.19.0 までが `compare/vA...vB`、以降が `releases/tag/vX.Y.Z`。
**過去の `compare/` のリンクは書き換えない**（形が混ざっても読み取りに支障は無い）。

### scripts/tagpr の更新

- **`scripts/tagpr/` を手で編集しない**。変更は kan/tagpr-scripts で行い、`git subtree pull -S` で
  取り込む。手順の正本は tagpr-scripts の README「Changing it」。
- **取り込んだ PR で、`tagpr.yml` と `tagpr-label.yml` の `uses: kan/tagpr-scripts/...@<SHA>` を
  取り込んだ commit へ上げる**。CI の `tagpr-subtree` ジョブ（`verify-subtree.mjs`）が食い違いで落ちる。
  Dependabot はこの行を上げない（`dependabot.yml` の `ignore`）。
- **subtree を取り込んだ PR はマージコミットでマージする（squash しない）**。理由は tagpr-scripts の README「Changing it」。

## ドキュメントの保守

API、構成、前提を変えたら **README.md も更新する**。使い方の説明は README に寄せ、本
ファイルには重複させない（拡張ルールの正本は CLAUDE.md、使い方の正本は README）。
