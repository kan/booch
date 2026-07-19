# Changelog

booch の変更履歴。書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

## [Unreleased]

## [1.6.0] - 2026-07-19

### Added

- `booch_wsl_ensure_systemd`（`lib/wsl.sh`）: WSL の `/etc/wsl.conf` に `[boot] systemd=true` を
  設定する。dockerd や `systemctl` を前提にするツール（docker / roji 等）は systemd 無しの WSL では
  導入・起動に失敗するため、その前段で呼ぶ。既存の `[boot]` があればその中へ差し込み、無ければ
  追記する（他セクションを壊さない）。冪等で、書いたときだけ WSL 再起動の案内を stderr へ出す。
  設定ファイルのパスは `BOOCH_WSL_CONF` で差し替えられる（テスト用）。

## [1.5.0] - 2026-07-15

### Added

- `booch_git_self_update`（`lib/git.sh`）の git fetch タイムアウトを環境変数
  `BOOCH_GIT_FETCH_TIMEOUT`（秒。既定 10）で調整できるようにした。SSH + 1Password などで
  初回接続にユーザー承認が挟まる環境では 10 秒では足りず、誤って fetch 失敗（= 自己更新を
  中断）と判定されることがあるため、利用側が延ばせるようにする。既定値は据え置き（後方互換）。

## [1.4.0] - 2026-07-15

### Added

- 提供ジョブ `jobs/shellcheck.sh`（`job_shellcheck`）を追加。ShellCheck を GitHub Releases の
  静的バイナリ（`shellcheck-<tag>.linux.<arch>.tar.xz`）から `/usr/local/bin/shellcheck` へ導入 /
  更新する。x86_64 / aarch64 対応。Ubuntu の apt 版は各リリースの版に張り付き（例: 24.04 は
  0.9.0 固定で SC2329 等の新しい検査が入らない）、CI が使う新しめの shellcheck とローカルが
  ずれるため、GitHub Releases から直接最新へ追従する。upstream がチェックサムを公開していない
  ため取得物は未検証（delta / codex 単体バイナリと同じ扱い）。

## [1.3.0] - 2026-07-15

### Added

- `lib/cleanup.sh`: `booch_cleanup_worktree_prune <repo>...`。指定した各 git repo で
  `git worktree prune` を回し、実体が消えた worktree の登録メタだけを掃除する（冪等・安全）。
- `lib/claude.sh`: 列挙・削除・MCP 登録のプリミティブを追加。`booch_claude_plugin_list` /
  `booch_claude_plugin_uninstall` / `booch_claude_marketplace_list` /
  `booch_claude_marketplace_remove` / `booch_claude_mcp_ensure`（remove→add の冪等登録）/
  `booch_claude_mcp_list` / `booch_claude_mcp_remove` / `booch_claude_autoremove_apply`
  （plan の Claude 系 kind を削除。非対象 kind は 2 を返し利用側へ委ねる）。CLI 出力の
  "❯" マーカー解析を 1 箇所（`_booch_claude_marked_names`）に集約。
- `lib/autoremove.sh`（新規）: `booch_autoremove_diff <kind> <desc> <desired...>`。stdin の
  実体一覧から desired 集合に無いものだけを "kind<TAB>id<TAB>desc" の plan 行にする汎用差分
  ドライバ（booch-win の lib/autoremove.ps1 と対称）。
- `lib/fs.sh`: `booch_fs_broken_symlinks <root...>`（root 直下 maxdepth 1 の壊れ symlink を
  "dest<TAB>target" で列挙）/ `booch_fs_remove_broken_symlink <dest>`（symlink かつ壊れている
  ことを再検証してから削除）。
- `lib/codex-config.sh`（新規）: `booch_codex_config_top_level_keys <source>` /
  `booch_codex_config_sync <source> [dest]`。TOML のトップレベルキーで `~/.codex/config.toml`
  をキー単位に冪等更新する（他キー・セクションを温存。`booch_set_toml_key` に委譲。booch-win の
  `Update-CodexConfig` と対称）。install ジョブ `jobs/codex.sh` とは別モジュール（`booch help
  codex` はジョブ、`booch help codex-config` は設定ヘルパー）。

いずれも消費側 dotfiles が直書きしていた汎用機構を booch へ寄せたもの（個人選択・環境固有値は
消費側に残す）。

## [1.2.1] - 2026-07-15

### Fixed

- `_booch_exec`（`lib/runner.sh`）がジョブを `bash -c "$inner"` で起動する際、`inner`
  （`declare -f` の全関数定義）を単一引数で渡していたため、消費側の lib/jobs が増えて
  `inner` が Linux の 1 引数上限 `MAX_ARG_STRLEN`（32 × ページサイズ = 128KiB。argv+envp
  合計の `ARG_MAX` とは別のハード上限）に達すると、`timeout` が bash を execve する時点で
  E2BIG（`Argument list too long`）となり、timeout 付きの全ジョブが失敗していた。`inner` を
  一時ファイルへ書き出して `bash <file>` で実行するよう変更し、引数長上限を回避する
  （ファイル実行にはこの上限が無い）。回帰ガードとして `declare -f` が 128KiB を超えても
  ジョブが完走することを検証するテストを追加（`tests/runner_test.sh`）。

## [1.2.0] - 2026-07-06

### Added

- 提供ジョブ `jobs/starship.sh`（`job_starship`）を追加。Starship プロンプトを GitHub
  Releases の musl 静的バイナリ（`starship-<arch>-unknown-linux-musl.tar.gz`）から
  `/usr/local/bin/starship` へ導入 / 更新する。同リリースの per-asset `.sha256`（ハッシュ
  64 桁のみ）で tar.gz を展開前に検証する（`lib/verify.sh`）。x86_64 / aarch64 対応。
  codex / circleci と同じ「DL → 検証 → 展開 → sudo install」パターン。

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

[Unreleased]: https://github.com/kan/booch/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/kan/booch/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/kan/booch/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/kan/booch/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/kan/booch/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/kan/booch/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/kan/booch/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/kan/booch/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/kan/booch/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/kan/booch/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/kan/booch/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/kan/booch/releases/tag/v1.0.0
