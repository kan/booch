# Changelog

booch の変更履歴。書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

## [Unreleased]

## [1.1.1] - 2026-07-06

### Fixed

- `booch_wsl_doctor_interop`（`lib/wsl.sh`）の WSL interop 行（`binfmt_misc registration` /
  `persistence config`）を `booch_doctor_row` に委譲し、他の doctor 行と体裁を統一した。
  従来は行を独自 `printf` で手描きしていたため、`[OK]` に緑色が付かず（生 `echo`）、さらに
  ラベルと `[OK]` の間の 1 スペースが欠けて他行と 1 桁ずれていた。同じ行描画を 2 箇所で
  持つとドリフトするため、描画は `booch_doctor_row` に一本化した（`lib/wsl.sh` の当該診断は
  `lib/doctor.sh` に依存する）。

## [1.1.0] - 2026-07-05

### Added

- `lib/doctor.sh` に `booch_doctor_symlinks "src|dest"...` を追加。配置一覧を受け取り、各リンク先が
  期待どおり src を指す symlink かを診断する（実体上書き・リンク切れ・宛先ずれ・未配置を warn で
  可視化。配置は再実行で冪等に直る前提のため missing=終了 1 にはしない）。
- `lib/doctor.sh` に `booch_doctor_apt_untracked <tracked...>` を追加。`apt-mark showmanual` と
  引数で渡した追跡集合の差分を監査する opt-in 機構（`BOOCH_DOCTOR_APT_AUDIT=1` のときだけ
  `apt-mark` を走らせ件数＋一覧を出す。既定は案内行のみ）。
- `booch_doctor_apt_pkg` を command 無しパッケージ対応に一般化。command 引数が空のときは
  `command -v` ではなく dpkg の install 状態で存在判定する（`language-pack-ja` のように対応
  コマンドを持たないパッケージ向け）。既存の 3 引数（command 非空）呼び出しの挙動は不変。

### Fixed

- `booch_set_toml_key` がトップレベルキーを EOF 追記していたため、ファイルが末尾でセクションを
  含む場合にキーがそのセクション内に入り込み、`[section].key` として解釈されて無効化していた
  （codex の `model_instructions_file` が実際に無効化した実害あり）。トップレベルキーは最初の
  `[section]` ヘッダより前で置換／挿入し、セクション内の同名キーには触れないよう修正した。

## [1.0.2] - 2026-07-01

### Added

- `booch help <name>` サブコマンドを追加。`lib/*.sh` / `jobs/*.sh` の冒頭ヘッダコメントと
  公開関数シグネチャ（`booch_xxx() { # args` 宣言）を抽出して表示する。引数なしの
  `booch help` はモジュール一覧（各 1 行説明付き）を出す。従来はモジュールの API を知るには
  ソースを直接開くしかなく、AI / 利用者が使い方を把握しづらかった。抽出ロジックは
  `lib/apidoc.sh` に切り出し（正本はソース。説明を二重管理しない）、将来の docs 生成でも
  再利用できるようにした
- `lib/doctor.sh` のラベル列幅を環境変数 `BOOCH_DOCTOR_LABEL_WIDTH`（既定 30）で
  上書きできるようにした。`booch_doctor_row` の列幅が `%-30s` 固定で、30 桁を超える
  ラベルが状態列（`[OK]` / `[WARN]` 等）とくっついて桁揃えが崩れていた。利用側が自分の
  ラベル集合の最長幅に合わせて渡せる。正の整数以外は既定 30 にフォールバックする

## [1.0.1] - 2026-06-29

### Fixed

- RETURN トラップの呼び出し元への漏れを修正（`lib/apt.sh` / `lib/uv.sh` / `lib/claude.sh`、
  `jobs/{go,delta,codex,aws,circleci}.sh` の計 9 関数）。temp 掃除の `trap '...' RETURN` は
  関数 return 後も解除されず呼び出し元のスコープに残り、呼び出し元の return 時に再発火する。
  再発火時には内側のローカル変数（`tmp` / `stage` / `deb`）が消えているため、`set -uo pipefail`
  で走る利用側 dotfiles で「未割り当て変数」エラーになりセットアップが中断していた。発火時に
  自身を解除する trap（`trap '...; trap - RETURN' RETURN`）＋変数ガード（`${tmp:-}`）に統一した

### Changed

- `booch_claude_plugin_ensure` が導入結果を stdout にタブ区切り 1 行
  `"<status>\t<old>\t<new>"`（status= installed | updated | current）で返すようにした。利用側
  （ジョブ）はこれを受けて `booch_result` に installed / updated / current と版を記録できる
  （役割分担はヘルパー＝動作・ジョブ＝報告のまま）。install 失敗時は従来どおり非 0 を返す

## [1.0.0] - 2026-06-29

初回公開リリース。WSL2 / Ubuntu 向けの再実行可能な開発環境ブートストラップ基盤。

### Added

- 並列ジョブランナー（`lib/runner.sh`）: bash-concurrent を土台に、ジョブ単位の
  タイムアウトと実行後サマリー（installed / updated / current / migrated / failed）を上乗せ。
  `booch_job` / `booch_run` / `booch_status` / `booch_result` / `booch_job_sync` を提供する
- ライブラリヘルパー（`lib/`）: arch / os / apt / github / verify / uv / claude / npm /
  fs / git / sudo / confirm / cleanup / wsl / docker / doctor / color。各ヘルパーは
  ネットワーク / sudo を継ぎ目（seam）に切り出してユニットテスト可能にしている
- 提供ジョブ（`jobs/`）: go / delta / codex / aws（CLI + Session Manager Plugin）/ circleci。
  非対話・冪等に「未導入なら導入、最新と異なれば更新」する
- 取得物の SHA256 検証（`lib/verify.sh`）: go は `dl.google.com` の `.sha256`、circleci は
  リリースの `checksums.txt` と照合し、不一致なら展開・sudo 導入前に止める
- ワンライナー bootstrap（`install.sh`）: 素の WSL2/Ubuntu から git / gh を確保し、dotfiles を
  clone して submodule（または sibling clone）で booch を取り込み、dotfiles の setup を起動する。
  `curl -fsSL .../install.sh | bash`（Windows 版の素 OS bootstrap は kan/booch-win が担う）
- CLI（`bin/booch`）: `init`（利用側 dotfiles 雛形の生成。冪等）/ `version`
- 利用側サンプル（`examples/`）: custom-job / bootstrap / lib-helpers
- セキュリティ施策: Dependabot（github-actions）/ Dependabot alerts / Secret scanning +
  Push protection / ShellCheck → SARIF を Code scanning へ連携
- ドキュメント: README.md / CLAUDE.md / SECURITY.md、`VERSION`、外部依存のないユニット
  テストとランナースモーク、GitHub Actions（構文 / shellcheck / テスト / スモーク）

[Unreleased]: https://github.com/kan/booch/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/kan/booch/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/kan/booch/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/kan/booch/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/kan/booch/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/kan/booch/releases/tag/v1.0.0
