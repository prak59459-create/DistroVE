# Distro VE

iPad 向けの高機能な動画編集アプリです。**無料・端末内処理**を軸に、Swift Playgrounds だけで作れる構成にしています。
計画書（Distro VE 計画書、2026-11-19）の方針案に沿って実装しています。

- 対応: iPad（iPadOS 17 以降。自動翻訳は iPadOS 18 以降）
- 作り方: Swift + SwiftUI（タイムラインは UIKit）、AVFoundation + Core Image（Metal）。FFmpeg は Swift Playgrounds に入れられないため、MKV・WebM などの取り込み（FFmpeg 相当の部分）は Swift で書いています
- 編集はオフラインで完結し、動画を端末の外に送りません

## iPad で動かす

1. この リポジトリの `DistroVE.swiftpm` フォルダーを iPad に入れます（GitHub の「Code → Download ZIP」を展開する、または Working Copy などの Git アプリで取得）。
2. ファイル App で `DistroVE.swiftpm` をタップすると Swift Playgrounds で開きます。
3. ▶︎（実行）を押します。初回はカメラ・マイク・写真への保存・音声認識の許可を求めます（使う機能のときだけ）。

App Store に出すときは、Swift Playgrounds の「App Store Connect にアップロード」から提出できます（Apple Developer Program への加入が必要です）。`Package.swift` の `bundleIdentifier` と `teamIdentifier` を自分のものに変えてください。

## 主な機能

| 分野 | できること |
| --- | --- |
| 基本編集 | トラック無制限、分割・トリミング・削除・リップル削除・スナップ、長押しで移動、一覧での並べ替え、マグネット（隙間を詰める）、元に戻す・やり直し無制限、自動保存＋手動保存 |
| 速度 | 倍速・スロー（0.1〜100 倍）、速度カーブ（6 種のプリセット）、逆再生（音声も逆に）、静止（フリーズ）、光学フローでコマを足す「なめらかスロー」（2・4・8 倍） |
| 変形・合成 | 位置・大きさ・回転・不透明度・切り抜き・反転・縦横比、3D の傾き、クロマキー、マスク（四角・円・線形・帯）、ブレンド 17 種、ピクチャーインピクチャー、調整レイヤー、モザイク枠 |
| 3D | 立体文字（押し出し・面取り）、3D モデルの読み込み（USDZ・OBJ・STL・PLY など）、基本の立体 5 種、照明・材質・動きの見本、奥行きと回転のキーフレーム（Metal で描画） |
| キーフレーム | 位置・大きさ・回転・不透明度・3D・色・エフェクト・マスク・音量すべて。補間 5 種 |
| 色 | 露出・明るさ・コントラスト・彩度・色温度など 13 項目、トーンカーブ（全体・RGB）、内蔵フィルター 14 種、LUT（.cube）読み込み |
| エフェクト | ぼかし・モザイク・グリッチ・RGB ずらし・VHS・ビネット・シェイク・フラッシュ・ズームパルスなど 18 種。拍に合わせて脈打たせる「ビート同期」 |
| トランジション | クロスフェード・黒フェード・白フラッシュ・スライド・ワイプ・ズーム・ぼかし・グリッチ・スピン・3D フリップ・3D キューブ（18 種） |
| テキスト・図形 | フォント・縁取り・影・帯・字間・行間・8 種の動き・スタイル見本、ステッカー、矢印・図形、手書き（Apple Pencil） |
| 音声 | BGM・効果音（内蔵 15 種、端末内で合成）、ナレーション録音、音量・フェード・キーフレーム、イコライザー、ボイスチェンジ、ノイズ除去（スペクトル減算）、音量の自動そろえ（-14 LUFS） |
| 字幕 | 手入力、自動文字起こし、SRT の読み込み・書き出し、スタイル・話者ごとの色（話者の自動判別も）・ずれ補正、自動翻訳（端末内） |
| AI（端末内） | 自動字幕、背景除去、無音カット、ハイライト抽出、BGM に合わせた自動編集、ショート動画への変換、手ぶれ補正、ビート検出 |
| 入出力 | MP4・MOV・HEVC・MP3・WAV・M4A・FLAC・JPG・PNG・HEIC・GIF の読み込み。MKV・WebM・AVI・Ogg・FLV・MPEG-TS・M2TS（AVCHD）は取り込むときに MP4 に変換（VP8・Vorbis は Swift で書いた解読器、中の字幕も読む）。MP4（H.264 / H.265）と GIF の書き出し、480p〜4K・24〜120fps、YouTube・TikTok・Instagram のプリセット、透かしなし |
| プロジェクト | 独自形式 `.disve`（JSON）、素材は「コピー」か「参照」を選べる、自動バックアップ（最大 20 世代）、フォルダー同期（iCloud Drive など）、テンプレート 8 種（GitHub から追加可） |
| 安全・性能 | プロキシ編集、プレビュー画質の切り替え、発熱・低電力時の自動軽量化、容量不足の警告、キャッシュの自動削除、クラッシュ後の復元、クラッシュログ（端末内） |
| 操作 | 経験に合わせた見せ方（かんたん・ふつう・プロ）、端末の性能に合わせた設定（3 段階を自動で判定）、ツールバーの並べ替え・非表示、タッチ・Apple Pencil・キーボードショートカット（変更可）・マウス／トラックパッド、ダーク／ライト、文字サイズ、色覚に配慮した配色、パネル位置の変更、VoiceOver（タイムラインはクリップ 1 つずつ操作できる） |

計画書の各項目（Q 番号）との対応と、まだできていないことは [docs/計画との対応.md](docs/計画との対応.md) にまとめています。

## ビルド時間

目標 10 秒・上限 60 秒（計画の指示）。CI（GitHub の macOS ランナー、3 コアの仮想 Mac）で毎回測っています。これまでの 10 回の計測では、差分ビルド（1 ファイル変更）が 2.2〜9 秒、クリーンビルドが 12.5〜30 秒で、どちらも目標の中です。SDK のモジュールキャッシュ作りから始める初回ビルド（最初の 1 回だけ）は 32〜90 秒で、60 秒を超えることがあります。内訳と、速く保つための決まりは [docs/ビルド時間.md](docs/ビルド時間.md) を見てください。

## フォルダー構成

```
DistroVE.swiftpm/          Swift Playgrounds で開くアプリ本体（1 モジュール）
  Package.swift            Swift Playgrounds 形式のマニフェスト（AppleProductTypes）
  Sources/Core/            純 Swift の部分（プロジェクト形式・編集・解析・テンプレートなど）。Linux でもビルド・テストできる
  Sources/Engine/          AVFoundation・Core Image・Vision・Speech を使う部分（合成・書き出し・解析・保存）
  Sources/UI/              SwiftUI の画面と UIKit のタイムライン
  Sources/App/             アプリの入口
Package.swift              開発用パッケージ（Core と Engine を DistroKit としてビルド・テスト）
Tests/DistroKitTests/      テスト（Linux で Core、macOS では Engine も実際に動かす）
content/                   GitHub から配るデータ（テンプレート・LUT）と一覧 manifest.json
scripts/                   ビルド時間の計測、配布データの一覧作成など
docs/                      計画との対応、ビルド時間、設計メモ
```

## 開発

Linux または macOS で Core（と macOS なら Engine）のテストを走らせられます。

```bash
swift test
```

iPadOS 向けの型チェックとアプリのビルド時間の計測（Xcode のある Mac で）:

```bash
scripts/ios-typecheck.sh
```

```bash
scripts/ios-build.sh
```

配布データ（`content/`）を変えたら、一覧を作り直します。

```bash
python3 scripts/update-content-manifest.py
```

## GitHub からの更新について

- App Store 版は App Store の通常の更新で配ります。審査後にプログラムを変えるコードのダウンロード・実行は App Store のガイドライン 2.5.2 で禁じられているため、アプリが GitHub から受け取るのは **テンプレートと LUT のデータだけ**です（`content/`）。変わったファイルだけをハッシュで確かめて取り込み、次回の起動で反映します。
- Swift Playgrounds 版のプログラムの更新は、アプリの中からは行えません（動いているアプリが自分のソースを書き換えて作り直す仕組みが無いため）。新しい版の `DistroVE.swiftpm` を取り込み直してください。検証の結果は [docs/計画との対応.md](docs/計画との対応.md) に書いています。

## ライセンス・素材

同梱の BGM・効果音は、アプリが端末内で合成した音源です。外部の音源ファイルは同梱していません。

VP8 の解読器（`Core/Formats/VP8Decoder.swift`・`VP8Predict.swift`・`VP8Tables.swift`）は、RFC 6386 に付いている参照用の解読器（Copyright (c) 2010, 2011, Google Inc.、BSD 3 条項ライセンス）を Swift に移植したものです。ライセンスの全文と著作権表示は `VP8Tables.swift` の先頭にあります。Vorbis の解読器は Xiph.Org の「Vorbis I specification」をもとに書きました。
