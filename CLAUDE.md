# CLAUDE.md - CamScanShare AI Agent Instructions

## プロジェクト概要

CamScanShareは、紙の文書をカメラでスキャンしてPDF化・共有するモバイルアプリです。CamScannerの簡易版として、スキャンとPDF共有に機能を絞っています。

## ドキュメントの構造と読み方

### 画面設計ドキュメント (`docs/`)

Astroベースの静的サイトで、画面設計を記述しています。

- `docs/src/pages/index.astro` - メインドキュメント。全画面の仕様を記載
- `docs/src/layouts/Layout.astro` - 共通レイアウト。Atlassian Design Systemのトークンを定義
- `docs/public/mockups/*.html` - 各画面のインタラクティブモック（iframe埋め込み用）

ドキュメントの各画面セクションは以下の構造です:
1. 左カラム: Phone frameに埋め込んだiframeモック（インタラクティブ）
2. 右カラム: 画面要素・インタラクション・技術的考慮点の仕様

### ドキュメントの起動

```bash
cd docs && npm run dev
```

### 開発前の画面設計確認（必須）

開発作業を開始する前に、必ず以下の手順で画面設計ドキュメントを確認し、機能と画面イメージを把握すること:

1. **ドキュメントサーバーを起動**: `cd docs && npm run dev` でAstro開発サーバーを起動
2. **ブラウザでページを開く**: `agent-browser open http://localhost:<port>` でドキュメントを開く
3. **aria snapshotで構造を把握**: `agent-browser snapshot` でページ全体のアクセシビリティツリーを取得し、画面構成・仕様テキストを読み取る
4. **各画面のPhone frameをスクリーンショットで確認**: 各画面セクションのiframe外枠（`.phone-frame`）までスクロールしてスクリーンショットを撮り、モックの見た目を視覚的に把握する

```bash
# 各画面のスクリーンショット取得例
agent-browser scrollintoview "#screen-document-list .phone-frame" && agent-browser screenshot /tmp/document_list.png
agent-browser scrollintoview "#screen-camera-scan .phone-frame" && agent-browser screenshot /tmp/camera_scan.png
agent-browser scrollintoview "#screen-page-list .phone-frame" && agent-browser screenshot /tmp/page_list.png
agent-browser scrollintoview "#screen-page-edit .phone-frame" && agent-browser screenshot /tmp/page_edit.png
```

この手順を省略して、ソースコードだけから画面仕様を推測してはならない。

### モバイルUX原則

- **実デバイスの操作感を最優先**: モックは見た目だけでなく、実際のスマートフォンで操作したときの体験を忠実に再現する
- **OSのシステムUI領域を考慮する**: ステータスバー、ホームインジケーター（ジェスチャーバー）等のOS標準UI領域を意識し、コンテンツが隠れたり誤タップが起きないようにレイアウトする
- **オーバーレイUIはコンテンツを隠さない**: アクションバー等のオーバーレイ要素が表示される際は、既存コンテンツを押し下げる等して、背後のコンテンツがアクセス不能にならないようにする
- **破壊的操作には確認を挟む**: 削除等の取り消せない操作は、確認ダイアログを表示してからの2ステップで実行する

### 変更時の同期ルール

モック・仕様ドキュメント・CLAUDE.mdは常に整合性を保つ。いずれかを変更したら、以下の3ファイルをセットで更新すること:

1. `docs/public/mockups/*.html` — インタラクティブモック
2. `docs/src/pages/index.astro` — 画面要素・インタラクションの仕様記述
3. `CLAUDE.md` — 画面一覧テーブルの概要

### モックファイルの編集ルール

- モックは `docs/public/mockups/` に配置する独立したHTMLファイル
- アプリのUIコンポーネントには [Material Web](https://github.com/material-components/material-web) を使用
- アイコンは Material Symbols (Google Fonts CDN) を使用
- フォントは `Noto Sans JP` + `Roboto`
- カラートークンは CSS custom propertiesで `--md-sys-color-*` を使用（Material Design 3準拠）
- Phone frame内（iframe）で表示するため、`height: 100vh` ベースのレイアウトにする
- インタラクションはCSS animationとvanilla JSで実装（フレームワーク不要）

### ドキュメントサイトの編集ルール

- ドキュメントのスタイリングは [Atlassian Design System](https://atlassian.design/components) に準拠
- CSSトークンは `--ds-*` プレフィックスで Layout.astro に定義済み
- 新しい画面セクションを追加する場合は、既存セクションの構造（`screen-section`）に倣う

## 画面一覧

| 画面名 | モックファイル | 概要 |
|--------|---------------|------|
| 文書一覧 | `document-list.html` | ホーム画面。文書リストビュー + 長押し複数選択で一括削除 + 新規スキャンFAB |
| カメラスキャン | `camera-scan.html` | 全画面カメラ撮影。紙検出ガイド + 左下に閉じる/サムネイルスタック切替 |
| 撮り直し | `camera-retake.html` | カメラスキャンの単発撮影モード。ページ編集から遷移し、1枚撮影で画像差替え後に自動で戻る |
| ページ一覧 | `page-list.html` | クロップ済みページのグリッド + 名前変更 + 長押しドラッグで並べ替え・削除 + 共有 |
| ページ編集 | `page-edit.html` | 左右スワイプで全ページ編集。回転/フィルタ（タップで単一・長押しで全ページ適用）/撮り直し + 破棄確認ダイアログ |

## 画面遷移

```
文書一覧 --[FABタップ]--> カメラスキャン --[サムネイルスタックタップ]--> ページ一覧
文書一覧 --[文書タップ]--> ページ一覧
カメラスキャン --[閉じるボタン（0枚時）]--> 文書一覧
ページ一覧 --[ページタップ]--> ページ編集
ページ一覧 --[ページ追加FAB]--> カメラスキャン --> ページ一覧
ページ一覧 --[共有ボタン]--> PDF変換 --> OS共有シート
ページ一覧 --[戻る]--> 文書一覧
ページ編集 --[撮り直しボタン]--> 撮り直し（単発撮影）--[撮影完了]--> ページ編集（画像差替え）
ページ編集 --[撮り直しボタン]--> 撮り直し --[✕キャンセル]--> ページ編集（変更なし）
```

## フィルタプリセット

アプリに搭載する画像フィルタ:

| フィルタ名 | 効果 | 用途 |
|-----------|------|------|
| オリジナル | 加工なし | そのまま保存 |
| くっきり | コントラスト強調 + 明るさ微調整 | 一般的な文書 |
| 白黒 | グレースケール + コントラスト強調 | 白黒文書、コピー用 |
| マジック（既定） | Flat-field補正（ガウシアンぼかし除算）+ コントラスト強調 | 照明ムラ・影の除去、CamScanner風の自動補正 |
| ホワイトボード | 高明度 + 高コントラスト + 彩度除去 | ホワイトボード撮影 |
| 鮮やか | 彩度強調 + コントラスト微調整 | カラー文書、図表 |

フィルタは今後追加可能な拡張設計とする。

## 技術的な注意事項

- 紙検出: エッジ検出 → 輪郭検出 → 最大矩形抽出（OpenCV等）
- 台形補正: 検出した4点を用いた射影変換
- PDF変換: 全ページをA4サイズにフィットさせて統合
- 共有: OS標準の共有API（Android: Intent.ACTION_SEND, iOS: UIActivityViewController）
- 連続撮影: 撮影後もカメラは起動したまま、完了ボタンで終了

## Androidアプリ (`androidapp/`)

### ビルド・テスト

```bash
# 環境変数（この環境固有）
export JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools

# ビルド
cd androidapp && ./gradlew assembleDebug

# テスト
cd androidapp && ./gradlew test

# 実機インストール
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### adbデバッグ手順

実機の画面をスクリーンショットで確認しながらデバッグする手順:

```bash
# 解像度をオーバーライド（スクリーンショット縮小 + uiautomator座標一致）
adb shell wm size 810x1800

# スクリーンショット取得
scripts/save-screenshot.sh /tmp/screen.png

# UI要素の座標を取得
adb shell uiautomator dump /sdcard/ui.xml && adb pull /sdcard/ui.xml /tmp/ui.xml

# タップ操作
adb shell input tap <x> <y>

# 作業完了後にオーバーライド解除（必ず実行）
adb shell wm size reset
```

### アーキテクチャ

Google公式「strongly recommended」に従ったシンプルな2層構造:

- **UI層** (`ui/`): Jetpack Compose + ViewModel (画面レベル) + `collectAsStateWithLifecycle`
- **Data層** (`data/`): Room + Repository + ImageFileStorage

Domain層・UseCaseは省略（ビジネスロジックが薄いため）。

### 開発で得られた教訓・注意点

#### CameraX

- `ImageProxy.toBitmap()` はEXIF回転を適用しない。`imageProxy.imageInfo.rotationDegrees` を取得して手動で回転すること。
- `ImageAnalysis` フレーム（640x480等）と `ImageCapture` フレーム（4032x3024等）は解像度が大きく異なる。分析フレームで検出した座標をそのままキャプチャ画像に適用してはならない。キャプチャ画像で再検出するのが確実。
- `PreviewView` はデフォルトでFILLスケーリング（画像を拡大して画面いっぱいに表示、はみ出し部分は中央クロップ）。検出座標をオーバーレイに描画する際は、画像と画面のアスペクト比差を考慮した座標変換が必要。

#### OpenCV (紙検出)

- OpenCVのエッジ検出パラメータ（Canny閾値、GaussianBlurカーネルサイズ等）は解像度に依存する。入力画像を一定サイズ（例: 最長辺500px）にダウンスケールしてから検出すると、解像度に関わらず安定した結果が得られる。ただし低解像度フレーム（640x480以下）はスキップすること。
- 台形補正（`warpPerspective`）はフル解像度の画像に対して適用する。

#### ファイル名・パス

- ドキュメント名にスラッシュ(`/`)を含めるとファイルパスが壊れる。日付フォーマットには `yyyy-MM-dd` を使い、ファイル名に使う際は `replace(Regex("[/\\\\:*?\"<>|]"), "_")` でサニタイズすること。

#### Compose ジェスチャー

- `pointerInput(Unit)` は初回コンポジション時のラムダをキャプチャし、再コンポジション時に更新されない。LazyList内で `index` 等が変わるコールバックを使う場合は、`rememberUpdatedState` でラップするか `pointerInput(key)` で再作成すること。
- `onGloballyPositioned { it.positionInParent() }` はスクロール可能なコンテナ内ではスクロール位置に依存する相対値を返す。画面上の絶対位置が必要な場合は `positionInRoot()` を使うこと。

#### ページ表示のアスペクト比

- スキャン画像を常にA4縦の枠に押し込まない。`computePageAspectRatio()` で画像の縦横比がA4に近い場合はA4にスナップし、極端に異なる場合は画像そのもののアスペクト比を使う。

#### 画面仕様ドキュメント

- 仕様にはプラットフォーム固有の実装詳細（ViewModel、Flow、StateFlow等）を書かない。ただし「DBに永続化する」「一時的な状態として保持する」のような粒度は、どのプラットフォームでも共通するため記述してよい。

## コマンドリファレンス

```bash
# ドキュメントの開発サーバー起動
cd docs && npm run dev

# ドキュメントのビルド
cd docs && npx astro build

# ビルド成果物のプレビュー
cd docs && npx astro preview
```
