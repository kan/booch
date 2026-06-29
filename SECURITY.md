# セキュリティポリシー

## 脆弱性の報告

booch に関する脆弱性を見つけた場合は、GitHub の Private vulnerability reporting で報告して
ください（公開 issue は修正前の露出を招くため避けてください）。

1. リポジトリの [Security タブ](https://github.com/kan/booch/security) を開く
2. "Report a vulnerability" を押す
3. 内容（再現手順・想定される影響・可能なら修正案）を記載する

## 取得物の信頼モデル

提供ジョブは各ツールを HTTPS + 公式配布元から取得して導入する。upstream がチェックサムを
公開しているツール（go / circleci）は SHA256 を照合し、未対応のものは「HTTPS + 配布元の
真正性」に依存する。詳細は README の「セキュリティ（取得物の信頼モデル）」を参照。

## 有効化しているセキュリティ施策

booch は依存パッケージを持たない Bash 製のため、一般的な依存スキャンはそのまま適用できない。
構成に合わせて次を採用している（採否の一覧は README の「リポジトリのセキュリティ施策」を参照）。

- **Secret scanning / Push protection**: トークン等の混入を検出・ブロック（GitHub 標準）
- **Dependabot（github-actions）**: ワークフローが使う GitHub Actions のバージョンを追従
- **Dependabot alerts / security updates**: 既知脆弱性のある Actions を検知・更新
- **Code scanning（ShellCheck → SARIF）**: Bash 静的解析の結果を Security タブへ連携
  （CodeQL は Bash 非対応のため代替）
