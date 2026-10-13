# iOS メモリ使用量の調査（2026-10-12）

使用中に重くなり終了する症状について、iOS の撮影・プレビュー・フィルタ・PDF 出力を確認した。現時点では実機のメモリ計測、JetsamEvent、クラッシュログを取得していないため、症状の原因や循環参照によるリークは未確定。以下はコードで確認できたメモリ保持とピーク使用量の増大要因、および対策である。

## 確認できた問題と対策

| 箇所 | 変更前 | 対策 |
| --- | --- | --- |
| `CameraScanViewModel.capturedPages` | 撮影終了まで全ページの補正済み原寸 `UIImage` を配列に保持。撮影枚数に比例して画素バッファが増える。補正処理もメインスレッドで実行していた。 | 補正後に1枚ずつ JPEG を保存し、配列にはファイル名と報告用メタデータだけを保持。補正・保存は画像処理 worker で実行。文書への引き渡し前に画面が破棄された場合は未確定ファイルを削除する。 |
| `PreviewStorageService` / `ImageStorageService` / `WorkingPreviewManager` の画像キャッシュ | `NSCache` に容量・件数上限がなく、画像サイズに応じた cost も指定されていない。working preview の表示を消してもキャッシュは残る。 | 共通の LRU キャッシュに変更。画素バッファの見積もりで persisted preview 32 MiB、縮小原画像 16 MiB、working preview 16 MiB の保持上限を設ける。メモリ警告で全消去し、編集画面終了でも working cache を消す。 |
| `WorkingPreviewManager.updatePreview` | フィルタ変更ごとに `Task.detached` を作る。SwiftUI 側のタスクがキャンセルされても処理が継続し、特に Core ML 推論が重なる可能性がある。 | 撮影補正・フィルタ preview・persisted preview・PDF 作成を共通 actor の同期処理で直列化。待機中のキャンセルを実行前に確認。古い結果はキャンセル状態と要求 ID で排除する。すでに実行中の同期処理は完了まで動くが、次の処理と重ならない。 |
| `LargePreviewImage` / `SmallPreviewImage` / ページ編集の `TabView` | ビューの状態に画像が残る。読み込みタスクがキャンセルされた後も古い画像を書き戻す。編集画面は全ページのプレビューを構築できる。 | 非表示時に画像を解放し、キャンセル後の書き戻しを防止。編集プレビューは現在ページと隣接ページのみ構築する。 |
| `PaperDetectionService.detectRectangle` | 通常撮影でも、出力無効の debug sink に渡す引数として原寸の四角形オーバーレイ画像を描画していた。 | 有効なデバッグセッションの場合だけ生成する。 |
| カメラフレーム / PDF ページ処理 / Core ML 推論 | UIKit・Objective-C・Core ML の一時オブジェクトを、処理単位で解放する autorelease pool がない。PDF はページ数に応じて一時オブジェクトが溜まる可能性がある。 | フレーム、worker の1ジョブ、PDF の1ページ、各推論を autorelease pool で囲む。カメラの CIContext は中間画像のキャッシュを無効化する。 |
| 撮影 callback / PDF 進捗タスク | 撮影処理前の失敗で continuation が解決されない可能性。PDF 作成中に view model が破棄されると、進捗 stream を finish せずに戻る。 | 撮影完了 callback でも撮影 ID に対応する continuation を解決。PDF 進捗 stream は view model の生存にかかわらず閉じる。重複した PDF 作成要求も防ぐ。 |

参考として、4032 × 3024 の画像1枚を RGBA8 で保持すると約46.5 MiB、10枚では約465 MiBになる。これは画素バッファだけの計算で、撮影・台形補正・フィルタの中間画像や GPU メモリを含まない。実測値ではない。

キャッシュ上限はキャッシュが保持する画像の画素バッファを見積もった値であり、アプリ全体のメモリ上限ではない。表示中の画像、Core Image / Core ML / カメラの内部バッファなどは別に存在する。キャッシュから追い出した画像は必要なときに再読み込みされるため、多数ページの往復では追加の読み込みが発生する。

## 検証

- `CLAUDE.md` と画面仕様を読み、Astro サーバー上のカメラ・ページ編集・ページ一覧モックを `agent-browser` で確認した。
- XcodeGen でプロジェクトを再生成して iOS 実機向けの署名なしビルドを確認した。
- iOS Simulator 向け `build-for-testing` を確認した。既存テストと追加テストはコンパイルできている。
- `ImageProcessingWorker.swift` と `ImageProcessingWorkerTests.swift` をそのまま一時 Swift Package にコピーし、macOS 上で2件の XCTest を実行した。20件の同時要求が1件ずつ動くこと、およびキャンセル済み要求が処理本体を実行しないことが通った。
- `ImageMemoryCacheTests` に容量超過・LRU・件数制限・メモリ警告時の画像解放、`CameraCaptureStorageTests` に未確定撮影のファイル回収と確定後の保持を追加した。これらの iOS テストは実行していない。
- 接続された iPhone と利用可能な Simulator runtime がないため、カメラの実操作、ページを往復する操作感、Core ML の実行、使用メモリ推移、終了原因は未検証。

## 実機での切り分け

1. 同じ機種・OS・文書で変更前と変更後を比較する。Xcode のメモリ表示または Instruments の Allocations で、各操作前後の値とピークを記録する。モデル初回ロードを含む初回と、それ以降を区別する。
2. カメラで10〜20枚連続撮影し、ページ一覧、文書一覧へ戻る。これを数回繰り返す。撮影済み原寸画像の保持が枚数に比例して増え続けないか、画面を閉じた後にカメラと view model が残らないか確認する。
3. 多数ページの編集画面で全ページを往復し、フィルタを連打する。影除去を含めて試し、同時推論がないか、画面を閉じた後に working preview が残らないかを確認する。ページのスワイプと撮り直しも確認する。
4. 複数ページの PDF を繰り返し生成する。画像・推論の一時オブジェクトがページをまたいで増えないかを見る。
5. Allocations の Mark Generation を操作の前後に入れ、同じ操作を繰り返して残る割り当てを調べる。Memory Graph では `CameraScanViewModel`、`CameraDelegate`、`WorkingPreviewManager`、`UIImage` からの保持経路を確認する。
6. 終了した場合は、その時刻の `CamScanShare` のクラッシュログと `JetsamEvent` を確認する。JetsamEvent に CamScanShare の終了理由があるかを見て、メモリによる終了と通常のクラッシュを区別する。

なお、影除去モデルは static に保持されるため、一度ロードするとモデルのメモリが残る。これはコード上は意図した常駐であり、リークの証拠ではないが、実際の大きさは計測が必要。また、PDF は JPEG 圧縮後の全ページと完成 PDF の `Data` をメモリに保持する実装のままで、大量ページではその分も増える。原寸1ページのフィルタ処理ピークも残る。今回の対策後でもこれらが終了原因になるなら、実測に基づいてモデルの解放方針や PDF のストリーム出力を検討する。

## 一次資料

- [Apple: NSCache.totalCostLimit](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit) — 既定値0は無制限。設定しても厳密な上限ではないため、今回は明示的な保持上限を持つ実装を使った。
- [Apple: Using Autorelease Pool Blocks](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html) — 多数の一時オブジェクトを作るループでは、局所的な pool によってピーク使用量を減らせる。
- [Apple: Gathering information about memory use](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use) — Memory Graph、Allocations、Mark Generation による調査方法。
- [Apple: Identifying high-memory use with jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports) — メモリ圧迫による OS の終了は、利用者からはクラッシュに見える。
