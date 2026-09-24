# Changelog

booch の変更履歴。書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

## [Unreleased]

## [1.16.0] - 2026-09-24

### Added

- `lib/doctor.sh` にラベル列の幅を求める 2 つの関数を足した。どちらも現在の
  `BOOCH_DOCTOR_LABEL_WIDTH` と最長ラベルの大きいほうを返す。長さは `printf` の `%-*s` に合わせて
  バイト数で数える。節の前に `BOOCH_DOCTOR_LABEL_WIDTH` をこの値にすれば、節全体の状態列が揃う。
  - `booch_doctor_labels_width label...`: 任意のラベルの集合から求める
  - `booch_doctor_symlinks_width "src|dest"...`: `booch_doctor_symlinks` と同じ規則でラベルを
    組み立てて求める。ラベルの組み立て規則を利用側へ写さずに済む

### Changed

- `lib/state.sh` と `lib/apt.sh` で、外部プロセスの起動を減らした。挙動は変わらない（#18）。
  - `_booch_state_file`: id の符号化とパスの返却を `printf -v` にし、1 文字ごとの fork と、
    呼び出しごとのコマンド置換の fork をなくした
  - `booch_state_changed`: 記録を `cat` ではなく `read` で読む
  - `booch_state_fresh` / `booch_apt_key_deadline`: 現在時刻を `date +%s` ではなく
    `printf '%(%s)T' -1` で取る。`lib/state.sh` は `date` に依存しなくなった

### Fixed

- `booch_doctor_symlinks` で、ラベル（dest の `$HOME` を `~` に短縮したもの）が
  `BOOCH_DOCTOR_LABEL_WIDTH`（既定 30）を超える行だけ状態の列が後ろへずれていた。関数内で幅を最長
  ラベルまで広げて描画する。広げた幅は関数を抜けると元に戻る（#16）。
- `booch_doctor_disk` が、空き容量が閾値を下回りヒントを渡さなかったときに終了コード 1 を返していた。
  `set -e` の呼び出し側はここで止まっていた。
- `booch_sudo_stop` が、キープアライブの子プロセスが既に無いと `pkill` の失敗で途中終了していた。
  `set -e` の呼び出し側では PID が残っていた。
- テストフレームワーク（`tests/lib.sh`）が、テスト関数の途中の assert の失敗を見逃していた。
  `if` の条件の中でテストを実行していたため `set -e` が無効になり、最後の行の終了コードだけで合否を
  決めていた。これで隠れていた上の 2 件と、捕捉の仕方を誤っていたテスト 4 件を直した。

## [1.15.0] - 2026-09-24

### Added

- `lib/state.sh` を足した。宣言と現状を畳んだハッシュが前回と変わったときだけ、または前回から
  一定時間が過ぎたときだけ処理を走らせるための状態記録（chezmoi の `run_onchange_` /
  `refreshPeriod` 相当）。公開 API は `booch_hash_args` / `booch_state_changed` /
  `booch_state_record` / `booch_state_fresh` / `booch_state_touch`。記録の置き場は
  `BOOCH_STATE_DIR`（未設定なら `${XDG_CACHE_HOME:-$HOME/.cache}/booch/state`）。lib は export
  しないので、既定を変えてジョブからも使う利用側は自分で export する。記録ファイル名は id を
  パーセントエンコードしたもの。

## [1.14.0] - 2026-09-17

### Changed

- `jobs/codex.sh` の導入方式を、GitHub Releases の単体バイナリから公式インストーラ
  （`https://chatgpt.com/codex/install.sh`）に変えた。Codex CLI は付随の実行ファイル
  （codex-code-mode-host / rg / bwrap）を含むパッケージとして配布されるようになり、単体
  バイナリだけでは正常に動かないため。
  - 導入先が `/usr/local/bin/codex` から `$CODEX_INSTALL_DIR`（既定 `~/.local/bin`）の symlink に
    変わる。**利用側で `~/.local/bin` を PATH に通しておく必要がある。** インストーラがシェルの
    設定ファイルへ PATH を追記しないよう、HOME を一時ディレクトリに差し替えて実行する。
  - 導入済みの版は導入先の codex から取る（PATH 上の codex は見ない）。
  - 更新も同じインストーラで行う。導入後、current と直前の版以外のパッケージを
    `$CODEX_HOME/packages/standalone/releases/` から削除する。
  - インストーラでの導入が済んでいれば、以前の booch が置いた `/usr/local/bin/codex`（`codex-cli`
    を名乗る実ファイルのときだけ）を毎回 sudo で削除する（一度失敗しても次の実行で再試行する）。
    撤去するのは booch 自身が置いた物だけで、npm 版など他の経路の codex は利用側に任せる。
  - パッケージの SHA256 はインストーラが照合する（README の検証表を更新）。
  - 公開 seam の `booch_codex_install` の引数を `<tag> <arch>` から `<version>`（rust-v を外した
    X.Y.Z）に変えた。`booch_codex_artifact` を削除し、`booch_codex_bin_dir` / `booch_codex_home` /
    `booch_codex_standalone_dir` / `booch_codex_current_release` / `booch_codex_fetch_installer` /
    `booch_codex_run_installer` / `booch_codex_prune_releases` / `booch_codex_legacy_path` /
    `booch_codex_remove_legacy` を足した。
- `examples/bootstrap.sh` の codex ジョブのタイムアウトを 300 秒にした（パッケージが大きくなったため）。

## [1.13.3] - 2026-09-15

### Fixed

- README「booch 本体の取り込み」の手順を直した。submodule をタグへ `checkout` した直後に
  `git submodule update --init` を実行していたため、`submodule add` の時点で記録された
  既定ブランチの版へ戻り、タグへの固定が消えていた。`git add vendor/booch` で版を記録して
  コミットする手順にし、記録前に update すると戻る理由も書いた。
- 文書と実物の食い違いを直した。
  - SHA256 検証済みのツールに Starship が抜けていた（SECURITY.md、CLAUDE.md）
  - README の検証表に ShellCheck（未検証）の行が無かった
  - `examples/bootstrap.sh` が導入する提供ジョブの列挙が実物と違った（README は shellcheck を
    含み、`examples/README.md` は starship が抜けていた）
  - CLAUDE.md がジョブの起動を `bash -c` と書いていた（実際は一時スクリプトを `bash <file>` で実行）
  - uv / Claude のインストーラを `curl | sh` 系と書いていた（実際は一時ファイルへ取得して実行）
  - CLAUDE.md のリリース手順が、README に無い固定版番号の更新確認を求めていた
- `install.sh` の `--booch-ref` の既定が v1.0.0 のままで、booch が見つからないときに古い版を
  clone していた。`--booch-ref` を指定しなければ、clone したタグのうち最新のリリースへ
  checkout するようにした（版番号を install.sh に持たないので、リリースのたびに更新する必要が無い）。

### Changed

- README の runner API 表に `booch_result_failed` / `booch_job_sync` / `booch_result_ver` を足した。
- README / CLAUDE.md / SECURITY.md / examples/README.md の表記を整えた（textlint の指摘、
  地の文のダッシュと並列の中黒、長い文の分割）。

## [1.13.2] - 2026-09-10

### Fixed

- `.github/workflows/release-tag.yml` が checkout の版によってタグ種別を誤検知しうるのを
  直した。`actions/checkout` はタグ push でも refspec `+<コミット SHA>:refs/tags/<名前>` で
  取る版があり、その場合ローカルの `refs/tags/<名前>` は annotated タグでもコミットを直接
  指すため `git cat-file -t` が `commit` を返す（`fetch-depth` を増やしても変わらない）。
  pin している v7.0.1 は全 ref を 1 回取るだけなので今は通っていたが、Dependabot が版を
  上げれば黙って赤へ変わる —— 対の booch-win（checkout v5）が実際にそれで落ちた。種別を
  見る前にタグ ref を取り直すようにして、版に依存しなくした。あわせて不要になった
  `fetch-depth: 0` を外した（`VERSION` を読むだけなら浅い clone で足りる）。

## [1.13.1] - 2026-09-10

### Added

- `.github/workflows/release-tag.yml`: `v*` タグの push で、タグが annotated であることと
  `VERSION` がタグ名と一致することを検査する。どちらもリリース手順が散文で定めているだけ
  だったため守られず、実際に過去のタグは lightweight / annotated が混在した。

### Changed

- `examples/custom-job.sh` の書き込み先を実 `$HOME/.config/myapp` から
  `${TMPDIR:-/tmp}/booch-example/myapp` へ移した。`examples/README.md` が最初に読ませる
  サンプルなのに、素で実行すると実ホームにディレクトリが残っていた。2 回目の実行で
  `current` になる冪等の見せ方は変えていない（そのため `mktemp -d` ではなく固定パス）。
- README「構成」の `lib/` ツリーに `lib/autoremove.sh` と `lib/codex-config.sh` を追記した。
  どちらも `booch help` には出るが README には無く、構成図だけでは存在に気付けなかった。
- README「前提」に、booch 本体は常に bash プロセスとして動くためログインシェルが zsh でも
  問題ない旨を明記した。あわせて `booch init` の雛形（`lib/scaffold.sh`）の symlink 例と
  `config/README.md` テンプレートに `.zshrc` の例を併記した。
- リリース手順（`CLAUDE.md`）のタグ作成を annotated（`git tag -a`）に統一した。lightweight
  タグは `git describe`（`--tags` 無し）から無視されるため、submodule で pin した版を
  `git submodule status` / `git describe` で確認すると 1 つ前のリリースが表示されていた。
  **今後のタグだけ**が annotated になる。既存タグは lightweight のまま残すので、過去版を
  pin して確認するときは `git describe --tags` を使う。

## [1.13.0] - 2026-09-06

### Added

- `booch_apt_keyring_expiry <keyring>`（`lib/apt.sh`）: keyring の署名鍵が「いつまで使えるか」を
  `unknown`（判定不能）/ `expired` / `forever` / epoch のいずれかで返す。`gpg --with-colons` の
  pub / sub のうち署名能力を持つレコードだけを見る。**署名副鍵を持つ keyring では副鍵だけを
  見る** ―― Release へ署名するのは副鍵なので、長寿命の主鍵に隠れて副鍵の期限切れを
  見落とさないため。取得は seam `booch_apt_keyring_records` に切り出してある。
- `booch_apt_keyring_usable <keyring> [grace-days]`（`lib/apt.sh`）: 上記の期限が猶予日数を
  過ぎても残るかを返す。判定不能なとき（gpg が無い等）は「使える」を返し、読めないことを
  理由に鍵を取り直さない。
- `booch_apt_key_deadline [grace-days]`（`lib/apt.sh`）: 「これより先に期限が来る鍵は取り直す」
  境界を epoch で返す。猶予日数の計算をここ 1 箇所に閉じ、判定側と診断側で drift させない。
- `BOOCH_APT_KEY_RENEW_DAYS`（既定 30）: 署名鍵を期限切れの何日前から取り直すか。
- `booch_doctor_apt_keyrings`（`lib/doctor.sh`）: サードパーティ repo の署名鍵の期限を診断する。
  対象は `sources.list.d` の `signed-by=` / `Signed-By:` が指す keyring なので、repo を足しても
  利用側の追記は要らない。期限切れ・期限間近なら repo 名を挙げて warn、正常なら「次に期限が
  来る repo と日付」を出す。読めなかった keyring は「期限なし」に混ぜず別行にする
  （判定不能を緑にしない）。`booch_doctor_apt_untracked` と同じく lib/apt.sh も source 済みが前提。

### Changed

- `booch_apt_add_repo` が、`<name>.list` と keyring がそろっていても**署名鍵が期限切れ
  （または期限間近）なら鍵を取り直す**ようになった。従来は両方あれば無条件にスキップして
  いたため、上流が鍵をローテーションしても手元の keyring は古いままで、期限が来た日から
  `apt update` が `EXPKEYSIG` で検証に失敗し、再実行しても直らなかった（GitHub CLI の鍵が
  2026-09-05 に期限切れになり顕在化）。取り直しに失敗しても repo 自体は既にあるので、
  警告して続行する。取り直しても上流がまだ旧鍵のままなら、その旨も警告する。
- `booch_apt_install_key` が **取得した鍵の中身が既存の keyring と同じなら書き込まない**
  ようになった。上流のローテーション待ちで取り直しが空振りする間、毎回 sudo で同じ内容を
  書き直すのを避ける。あわせて `gpg --dearmor` を sudo の前にローカルの一時ファイルへ
  実行するようにし（配置する中身を比較前に確定させるため）、`sudo chmod go+r` は
  `install -m 0644` に統合した。鍵取得の `curl` には `--max-time 30` を付けた ―― 猶予期間中は
  毎回ここを通るので、応答しない網でセットアップがぶら下がらないようにする。
- `booch_apt_resolve_codename` が省略可能な第 4 引数 `name` を取るようになった。渡すと、既に
  `<name>.list` があるときはそこに記録されたコードネームをそのまま返し、`dists/` の HEAD
  チェックを省く。`booch_apt_add_repo` は鍵の期限切れを見るために毎回呼ぶ必要があり、
  呼び出しを `.list` の有無で囲えなくなったので、通信を省く判断をこちらへ移した
  （オフライン時に誤って fallback のコードネームへ落ちるのも防ぐ）。3 引数の呼び出しは
  従来どおり毎回 HEAD で解決する。

## [1.12.0] - 2026-09-04

### Added

- `booch_claude_marketplace_update`（`lib/claude.sh`）: marketplace を 1 つだけ更新する。
  `booch_claude_marketplace_update_all` は 1 つでも壊れていれば非 0 になるが内訳が分からない
  ため、「どの marketplace が失敗したか」を報告したい利用側はこちらを名前ごとに呼ぶ
  （正常時は update_all を 1 回、非 0 のときだけ名前ごとに切り分ける使い方を想定）。
- `booch_result_failed <tool> [reason]`（`lib/runner.sh`）: 理由付きの `failed` 行を書く
  ジョブ向けの入口。ジョブ全体は成功のまま内訳の 1 件だけを落とす使い方では
  bash-concurrent の失敗ログが出ないため、理由を書ける場所がサマリー以外に無かった。
  サマリーは `failed` 行の後ろに理由を表示する（理由なしの行は従来どおりの見た目）。

### Changed

- marketplace 系ヘルパー（`ensure` / `update` / `update_all`）の失敗の返し方を
  `booch_claude_plugin_ensure` と同じ「動作＝ヘルパー / 報告＝ジョブ」の契約へ揃えた。
  **成功なら無出力で 0、失敗なら理由 1 行を stdout に出して非 0** を返し、CLI の全文は
  stderr へ流してジョブのログに残す。利用側は
  `if ! reason=$(booch_claude_marketplace_update "$m"); then booch_result_failed ... "$reason"; fi`
  と書ける。従来 `update_all` は出力を `>/dev/null 2>&1` で捨てており、「1 marketplace
  could not be refreshed: \<name\>」のような失敗理由が消えて、marketplace が参照できなく
  なったことに気付けないままプラグインが古い版で凍結する事故を招いていた。
  理由の 1 行化（空白潰し・進捗断片の除去・長さの切り詰め）は CLI の出力書式に依存する処理
  なので、利用側ではなく `lib/claude.sh` が持つ。

### Fixed

- `booch_result` が値に含まれる `|` と改行をそのまま書いていたため、サマリーの読み出し
  （`IFS='|' read -r`）が別フィールド・別行として解釈して行が壊れていた。ブラケット表現の
  1 回の展開で空白へ潰すようにした（CLI の出力をそのまま失敗理由に渡せるようにするため。
  コマンド置換を使うと 1 行あたり数回の fork になり、サマリー数十行ぶんが無駄になる）。

## [1.11.1] - 2026-08-31

### Fixed

- `booch_claude_plugin_ensure`（`lib/claude.sh`）が `claude plugin install` の出力を stdout へ
  流したままにしていたのを、stderr へ寄せるようにした。この関数の stdout は
  `"<status>\t<old>\t<new>"` の outcome 行だけという契約なので、install の進捗表示が混ざると
  呼び出し側の `out=$(booch_claude_plugin_ensure ...)` がそれごと取り込み、status が進捗表示に
  化けてサマリー行が壊れていた。**新規 install のときだけ**起きる（update は元から
  `>/dev/null`）ので、既に導入済みの環境では表面化しない。本体側の `booch_claude_ensure` は
  導入出力を `>&2` に寄せてあり、その非対称も解消した。回帰ガードのテストを追加。

## [1.11.0] - 2026-08-17

### Added

- `booch_wsl_interop_conf`（`lib/wsl.sh`）: WSLInterop の binfmt.d 永続設定の実在パスを返す
  （`/usr/lib/binfmt.d` → `/etc/binfmt.d` の順。どちらも無ければ既定パスを返して非 0）。
  不在時も空にしないので、案内文が「どこへ書くか」を常に示せる。既定パスは
  `BOOCH_WSL_INTEROP_CONF` で上書きできる（テスト用の継ぎ目）。
- `booch_wsl_binfmt_unit_state`（`lib/wsl.sh`）: `systemd-binfmt.service` の状態を
  `masked` / `present` / `none`（systemctl 無し）で返す。

### Changed

- `booch_wsl_doctor_interop`（`lib/wsl.sh`）が `systemd-binfmt unit` の行を追加し、
  masked なら warn を出して `unmask` を案内するようにした。masked だと **binfmt.d の再適用も、
  WSL が drop-in で仕込む WSLInterop の再登録も走らない**ため、いちど登録が消えると戻る経路が
  無くなる。この状態は登録が生きている間は無症状で、`.exe` が動かなくなって初めて表面化する。

### Fixed

- `booch_wsl_doctor_interop` が「永続設定はあるのに binfmt_misc の登録だけ消えた」ケースで、
  `WSLInterop disabled` とだけ表示して復旧方法を出していなかったのを、即時復旧コマンドを
  添えるようにした。案内ブロックは `persistence config` が warn のときにしか出ておらず、
  実際に起きるのはこちら（永続設定は残ったまま登録だけ落ちる）なので、警告を見ても手が
  出せなかった。
- 復旧の案内を `systemctl restart systemd-binfmt` から binfmt_misc の `register` への直接
  書き込みへ変更した。前者は `systemd-binfmt.service` が masked のとき**エラーも出さずに
  何もしない**ため、案内どおり実行しても直らない。register への書き込みは masked でも効く。

## [1.10.0] - 2026-08-03

### Changed

- `booch_npm_local_install`（`lib/npm.sh`）が、src に `package-lock.json` が無いときは
  `npm install` に続けて `npm update` も走らせるようにした。dest に残る lockfile は初回
  install の副産物だが、`npm install` は**それが package.json のレンジを満たす限り古い版を
  保持する**ため、レンジ内に新版が出ても再実行で永久に前進しなかった（dotfiles の textlint が
  `^15.7.1` のまま 15.8.0 へ上がらず、doctor が毎回「更新あり」を出し続けた）。src に lockfile が
  **ある**ときは意図された版固定とみなし従来どおり install のみ（update しない）。レンジ外
  （メジャー跨ぎ）は動かないので、`package.json` の手 bump が要る点は変わらない。

## [1.9.0] - 2026-07-29

### Added

- `booch_cleanup_docker_df_rows`（`lib/cleanup.sh`）: `docker system df` の全行を
  `Type|Size|Reclaimable` で返す。複数のセルが要るときに df を何度も叩かないための入口で、
  テストの継ぎ目でもある（`booch_cleanup_docker_df_field` もこれを通る）。

### Changed

- `booch_cleanup_docker_prune_deep` の見込み表示（未使用イメージ / ビルドキャッシュ）が
  `docker system df` を 2 回実行していたのを 1 回にした。df の集計はイメージ・キャッシュが
  多いほど重いので、**deep prune が要る環境ほど**（実測でイメージ 44GB / キャッシュ 41GB 規模）
  確認プロンプトが出るまでの待ちが倍になっていた。1 セルだけ引くときの挙動は変わらない。
- CI（`.github/workflows/ci.yml`）の ShellCheck を、ランナー同梱版から `jobs/shellcheck.sh`
  による最新版導入に切り替えた。同梱版はランナーイメージの版に張り付くため手元とズレ、
  「ローカルで赤・CI で緑」が起きていた（手元の 0.11.0 で `tests/delta_test.sh` の SC2329 が
  出る一方、CI は緑）。booch 自身のジョブを CI で使うため、`jobs/shellcheck.sh` の実地検証も
  兼ねる。検査コマンド（`shellcheck -x` のグロブ）は変更していない。

### Fixed

- `tests/delta_test.sh`: ShellCheck 0.11.0 で追加された SC2329（未呼び出し関数）が、
  `job_delta` から間接的に呼ばれるスタブに対して出ていたのを、既存の SC2317 抑制と同じ枠で
  理由付きで抑制した。

### Security

- ワークフローの `uses:` を可動タグから commit SHA ピンへ変更した（`actions/checkout` /
  `redhat-plumbers-in-action/differential-shellcheck`）。タグ付け替えを防ぐとともに、
  可動タグでは PR が出なかったパッチ更新（differential-shellcheck 同梱の shellcheck を含む）が
  Dependabot の PR として可視化される。

## [1.8.0] - 2026-07-29

### Added

- `booch_cleanup_docker_prune_deep [assume_yes]`（`lib/cleanup.sh`）: 未使用タグ付き
  イメージ（`docker image prune -af`）とビルドキャッシュ全体（`docker builder prune -af`）を
  回収する深い prune。安全版（`booch_cleanup_docker_prune_safe`）は dangling しか消さないため、
  タグ付き未使用イメージとキャッシュが青天井に溜まる。消し過ぎると再取得・再ビルドが走るので
  既定で y/N 確認を挟み（非対話は見送り）、volume は DB データを含みうるため触らない。
- `booch_cleanup_docker_df_field <type> <field>`（`lib/cleanup.sh`）: `docker system df` の
  1 セル（size / reclaimable）を返す seam。deep prune の回収見込み表示に使う。
- `booch_confirm_yes_no <prompt> [assume_yes]` / `booch_confirm_ask <prompt>`
  （`lib/confirm.sh`）: 更新確認に限らない汎用の y/N。破壊的操作の実行可否を尋ねる用途。
- `booch_docker_daemon_config_ensure <json_fragment> [jq_post_filter]`（`lib/docker.sh`）:
  `daemon.json` を渡したキーだけ更新する（丸ごと上書きせず利用者の他キーを温存。差分が
  無ければ書かない）。書く前に `dockerd --validate` を通し、失敗時は現行設定を残す。
  `jq_post_filter` で旧キーの削除など整理も渡せる。実体パスは
  `BOOCH_DOCKER_DAEMON_CONFIG`、更新有無は `BOOCH_DOCKER_DAEMON_CONFIG_CHANGED`。
- `booch_docker_daemon_restart_if_idle`（`lib/docker.sh`）: 設定を更新したときだけ docker を
  再起動する。稼働中コンテナがあれば再起動せず案内に留める（日々の setup で作業中のスタックを
  落とさないため）。
- `booch_doctor_disk <label> <path> <warn_gb> [hint]`（`lib/doctor.sh`）: ファイルシステムの
  空き容量行。閾値未満で warn（＋案内）。ディスク逼迫は放置すると導入・ビルドが静かに失敗
  するため診断に載せられるようにする。

## [1.7.1] - 2026-07-25

### Fixed

- `booch_doctor_tool`（`lib/doctor.sh`）が current と latest の不一致を一律 `outdated`
  （update available）にしていたため、手元が配布元より **新しい** ときにも更新を促していた
  （自己更新するツールがレジストリの反映より先行する / プレリリースを入れている場合。実例:
  claude 2.1.220 に対し npm registry が 2.1.219 で「update available: 2.1.219」）。順序で
  比較し、latest の方が新しいときだけ `outdated` にする。手元が先行しているときは `ok` で
  latest を併記するに留める。

### Added

- `booch_ver_gt <a> <b>`（`lib/doctor.sh`）: 正規化済みバージョンの順序比較（`sort -V`）。
  利用側が「遅れているときだけ警告する」判定を書けるようにする公開ヘルパー。

## [1.7.0] - 2026-07-25

### Added

- `booch_result_ver`（`lib/runner.sh`）: 導入の前後で取った版から installed / updated / current を
  判定してサマリー行を記録する。「入れてみるまで最新版が分からない」自己更新型のツール
  （インストーラ任せ / `npm install` / `uv tool upgrade` 等）向け。導入後の版だけを `current` で
  記録すると更新しても「変化なし」としか出ず、サマリーが更新の記録として機能しないため。
  導入前に最新版を引けるツールは従来どおり `booch_job_sync`。
- `booch_claude_ensure`（`lib/claude.sh`）: Claude Code 本体を導入/更新し、結果を
  `booch_claude_plugin_ensure` と同じ `"<status>\t<old>\t<new>"`（installed / updated / current）
  で返す。版を導入の前後で取り直すため、利用側は本体の更新をサマリーへ `old → new` で出せる
  （導入後の版だけを見ると更新が `current` に潰れ、本体だけプラグインと非対称だった）。導入
  コマンドの出力は outcome 行に混ざらないよう stderr へ寄せる。`booch_claude_install`
  （出力なし）は互換のまま残す。
- `booch_aws_ssm_latest`（`jobs/aws.sh`）: Session Manager Plugin の最新版を公式の
  `/latest/VERSION` から取る seam。

### Fixed

- `job_aws`（`jobs/aws.sh`）の Session Manager Plugin が初回導入時の版で凍結し、以後どれだけ
  古くなっても更新が入らなかった。「upstream に版確認の手段が無い」として未導入時のみ導入して
  いたが、実際には `/latest/VERSION` が版を返すので、AWS CLI と同じく `booch_job_sync` による
  版比較で更新する。版を取れないとき（オフライン等）は空版での誤 update を避け、従来どおり
  「未導入なら導入・導入済みは現状維持」へフォールバックする。

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

[Unreleased]: https://github.com/kan/booch/compare/v1.16.0...HEAD
[1.16.0]: https://github.com/kan/booch/compare/v1.15.0...v1.16.0
[1.15.0]: https://github.com/kan/booch/compare/v1.14.0...v1.15.0
[1.14.0]: https://github.com/kan/booch/compare/v1.13.3...v1.14.0
[1.13.3]: https://github.com/kan/booch/compare/v1.13.2...v1.13.3
[1.13.2]: https://github.com/kan/booch/compare/v1.13.1...v1.13.2
[1.13.1]: https://github.com/kan/booch/compare/v1.13.0...v1.13.1
[1.13.0]: https://github.com/kan/booch/compare/v1.12.0...v1.13.0
[1.12.0]: https://github.com/kan/booch/compare/v1.11.1...v1.12.0
[1.11.1]: https://github.com/kan/booch/compare/v1.11.0...v1.11.1
[1.11.0]: https://github.com/kan/booch/compare/v1.10.0...v1.11.0
[1.10.0]: https://github.com/kan/booch/compare/v1.9.0...v1.10.0
[1.9.0]: https://github.com/kan/booch/compare/v1.8.0...v1.9.0
[1.8.0]: https://github.com/kan/booch/compare/v1.7.1...v1.8.0
[1.7.1]: https://github.com/kan/booch/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/kan/booch/compare/v1.6.0...v1.7.0
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
