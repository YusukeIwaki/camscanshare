# CamScanShare

紙の文書をスキャンしてPDF化し、Google DriveやAirDropなどで共有することに特化したモバイルアプリです。

## 機能概要

- **スキャン**: カメラで紙の文書を撮影。紙を自動検出し、台形補正・クロップを実行
- **調整**: 回転、フィルタ適用（くっきり・白黒・ホワイトボード等）で文書を読みやすく
- **共有**: PDF変換し、OS標準の共有機能（Google Drive, AirDrop等）で即座にシェア

## 画面構成

1. **文書一覧** - ホーム画面。過去にスキャンした文書の一覧
2. **カメラスキャン** - カメラで紙を撮影。紙検出ガイド付き
3. **ページ一覧** - 撮影したページのグリッド表示。共有・編集・ページ追加
4. **ページ編集** - 個別ページの回転・フィルタ適用・撮り直し

## プロジェクト構造

```
camscanshare/
├── docs/                        # 画面設計ドキュメント (Astro)
│   ├── src/
│   │   ├── layouts/Layout.astro # ベースレイアウト (Atlassian Design System)
│   │   └── pages/index.astro    # メイン設計ドキュメント
│   └── public/mockups/          # 画面モックHTML (Material Web)
│       ├── document-list.html   # 文書一覧画面モック
│       ├── camera-scan.html     # カメラスキャン画面モック
│       ├── page-list.html       # ページ一覧画面モック
│       └── page-edit.html       # ページ編集画面モック
├── README.md
└── CLAUDE.md
```

## 画面設計ドキュメントの閲覧

```bash
cd docs
npm install
npm run dev
```

ブラウザで http://localhost:4321/ を開くと画面設計ドキュメントが表示されます。各画面セクションにはインタラクティブなモックが埋め込まれており、クリック操作でアニメーションを確認できます。

## デザインシステム

| 対象 | デザインシステム |
|------|-----------------|
| ドキュメントサイト | [Atlassian Design System](https://atlassian.design/components) |
| アプリ画面モック | [Material Web](https://github.com/material-components/material-web) |
