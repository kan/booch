# examples

booch を利用側 dotfiles から使うためのサンプル集。どれも汎用部分だけを示し、個人固有・
業務固有の値は持ち込まない（それらは利用側に置く方針）。CI では実行せず、コピーして
自分の環境に合わせる出発点として使う。

ランナー自体の挙動を確認するスモークテストは `tests/smoke.sh`（CI が実行）にある。
サンプルとスモークは役割が異なる: サンプルは「どう組むか」を示す読み物、スモークは
ランナーの回帰確認。

## 読む順番

1. **[custom-job.sh](custom-job.sh)** — 最小構成。booch を source し、自分用の custom job を
   登録して並列実行する。個人固有処理を booch 側に持ち込まない切り分けが分かる。
2. **[bootstrap.sh](bootstrap.sh)** — 現実的なブートストラップ。提供ジョブ（go / delta /
   codex / aws / circleci）を sudo 事前キャッシュ付きで一括導入する。実際に導入する
   （network + sudo）ため、雛形としてコピーして使う。
3. **[lib-helpers.sh](lib-helpers.sh)** — 補助ヘルパー（fs.sh の symlink / TOML 更新、
   confirm.sh の更新確認、sudo.sh の事前キャッシュ）の使い方を示す小品。安全な操作は
   一時ディレクトリで実際に動かせる。
