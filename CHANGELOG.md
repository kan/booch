# Changelog

booch の変更履歴。書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

## [Unreleased]

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
- CLI（`bin/booch`）: `init`（利用側 dotfiles 雛形の生成。冪等）/ `version`
- 利用側サンプル（`examples/`）: custom-job / bootstrap / lib-helpers
- セキュリティ施策: Dependabot（github-actions）/ Dependabot alerts / Secret scanning +
  Push protection / ShellCheck → SARIF を Code scanning へ連携
- ドキュメント: README.md / CLAUDE.md / SECURITY.md、`VERSION`、外部依存のないユニット
  テストとランナースモーク、GitHub Actions（構文 / shellcheck / テスト / スモーク）

[Unreleased]: https://github.com/kan/booch/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/kan/booch/releases/tag/v1.0.0
