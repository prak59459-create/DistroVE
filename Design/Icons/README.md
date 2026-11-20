# アイコンの元の画像（開発者用）

ChatGPT で作ったアイコンの画像をここに置き、`python3 scripts/icon_pack.py` でアプリの `DistroVE.swiftpm/Assets.xcassets` に入れます（Pillow と numpy が要ります）。アプリを使う人がアイコンを作ることはありません。プロンプトと作り方は [docs/アイコン制作プロンプト.md](../../docs/アイコン制作プロンプト.md) にあります。

| 置くもの | ファイル名 |
| --- | --- |
| 6 枚の画像（1 枚に 8 列 × 6 行の 48 個） | `sheet-1.png` 〜 `sheet-6.png` |
| 細かく作った画像（1 枚に 4 列 × 4 行の 16 個。使うときだけ） | `detailed-1.png` 〜 `detailed-20.png` |
| アプリのアイコン | `app.icon.png`（ダーク用の `app.icon.dark.png`・色付け用の `app.icon.tinted.png` は無くてもよい） |
| ホームのロゴ・背景 | `brand.logo.png`・`brand.background.png` |
| 1 つだけ作り直した絵 | `edit.split.png` のように、絵の名前（一覧はプロンプトの説明書の「9. 全部の一覧」） |

- PNG・JPEG・WebP のどれでも読めます。
- 同じ絵が何か所かにあれば、`sheet` より `detailed`、`detailed` より 1 つずつ置いた画像を使います。
- `preview.png`（確認用の一覧）はスクリプトが作ります。リポジトリには入れません。
