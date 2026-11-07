# セキュリティポリシー

## 脆弱性の報告

booch に脆弱性を見つけたら、公開の Issue には書かず、GitHub の [Private vulnerability reporting](https://github.com/kan/booch/security/advisories/new) から報告してください。報告の内容は、修正を公開するまでメンテナーにだけ見えます。

報告には次の内容を書いてください。

- 脆弱性の内容
- 再現の手順
- 想定される影響（可能なら修正案も）

受け取った報告は、できるだけ早く確認して返信します。

## 取得物の信頼モデル

提供ジョブは各ツールを HTTPS + 公式配布元から取得して導入する。upstream がチェックサムを
公開しているツール（go / circleci / starship）は SHA256 を照合し、それ以外は「HTTPS + 配布元の
真正性」に依存する。詳細は README の「セキュリティ（取得物の信頼モデル）」を参照。

## 有効化しているセキュリティ施策

booch は依存パッケージを持たない Bash 製のため、一般的な依存スキャンはそのまま適用できない。
構成に合わせて次を採用している（採否の一覧は README の「リポジトリのセキュリティ施策」を参照）。

- Secret scanning / Push protection: トークン等の混入を検出し、push を止める（GitHub 標準）
- Dependabot（github-actions）: ワークフローが使う GitHub Actions のバージョンを追従する
- Dependabot alerts / security updates: 既知脆弱性のある Actions を検知して更新する
- Code scanning（ShellCheck → SARIF）: Bash 静的解析の結果を Security タブへ送る
  （CodeQL は Bash に対応していないため、その代わりに使う）
- Code scanning（CodeQL default setup、extended）: CodeQL が対応する部分（GitHub Actions の
  ワークフローと `scripts/tagpr/` の JavaScript）を解析する
