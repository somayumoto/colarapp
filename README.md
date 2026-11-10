# 色々変え

カメラ映像をリアルタイムで色変換し、**上に変換後・下に元の映像**を表示するiPhone／iPad向け試作アプリです。上下は同じフレーム・同じ範囲です。

## 起動

1. `色々変え.xcodeproj` をXcodeで開きます。このプロジェクトはXcode 27の `.xcproj` 形式です。
2. 実機を実行先に選び、必要なら Signing & Capabilities のTeamを自分のものに変更して実行します。
3. 初回にカメラの使用を許可します。映像を保存・送信する機能はありません。

対応OSはiOS／iPadOS 18以降。シミュレーターでは色見本から開始します。実機でも右上の「色見本」でカメラを使わずに見え方を試せます。

## 操作

- **色の変え方**：赤の強さを青に／赤と青を交換／赤い部分を強調／変換なし。
- **強度**：0%で原画、100%で選んだ変換です。「赤い部分を強調」は無彩色の背景に、赤が他の成分より優勢な場所を青で示します。
- **右上の設定ボタン → 解像度**：480p（640×480）、720p（1280×720）、1080p（1920×1080）、4K（3840×2160）。初期設定は720pです。
- **フレームレート**：30／60 fps。初期設定は30 fpsです。
- **映像全体を表示**：オンで全体を収めます。オフでは表示枠に合わせて中央を切り取ります。いずれも上下で同じ範囲になります。

設定はアプリの再起動後も保持されます。カメラが対応する解像度・フレームレートだけを使用し、要求した組み合わせが使えない場合は対応する設定へ変更して理由を表示します。「選択中」と「撮影中」を設定画面で確認できます。撮影中の寸法は受信した映像バッファから取得しています。fps表示は設定値です。

R成分だけを青にする方式では、白や黄色も青くなります。見やすい変換方式・強度を、実際に使う人と調整してください。

## 処理の構成

SwiftUIで操作、AVFoundationで背面カメラ1台の8 bit SDR映像を取得し、`CVMetalTextureCache` でYCbCrの2平面を参照します。Metalの1回の描画でRGBへの変換、色変換、上下表示を行います。

CPUで毎フレームのUIImageを作成せず、保持する入力は最新1枚だけです。古いフレームを破棄し、GPUへの投入は最大2枚に制限します。新しいフレーム・設定変更・表示サイズ変更時に描画します。バックグラウンド移行時や色見本へ切り替えたときはカメラを停止します。HDR・手ぶれ補正を無効にし、YCbCrのfull／video range、BT.601／709／2020の行列を区別します。

主なファイル：

| ファイル | 担当 |
| --- | --- |
| `色々変え/ContentView.swift` | 上下比較画面、強度、解像度などの設定 |
| `色々変え/CameraSettings.swift` | 変換方式と撮影設定 |
| `色々変え/CameraCapture.swift` | 権限、撮影、最新フレーム、対応形式の選択 |
| `色々変え/CameraRenderer.swift` | GPUへの入力、描画タイミング、回転 |
| `色々変え/ColorShaders.metal` | 実際の色変換と上下表示 |

設計上の参考：[Appleのカメラ映像フィルターサンプル](https://developer.apple.com/documentation/avfoundation/avcamfilter-applying-filters-to-a-capture-stream)、[activeFormatの設定](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat)。

## 検証

Macの実GPUで、アプリと同じMetalソースに対してテストします。

```sh
Tests/run-metal-tests.sh
```

変換方式・0/50/100%の強度、原画が変わらないこと、YCbCrの色、回転、fit／fill、上下の一致を検証します。

シミュレーターで画面操作も検証できます。`simctl list devices available` のデバイスIDを渡してください。

```sh
Tests/run-ui-tests.sh <シミュレーターのデバイスID>
```

操作テストは一時フォルダに独立したテストプロジェクトを作るため、アプリ本体のプロジェクトや署名設定を変更しません。実行ログとスクリーンショットを含む `.xcresult` の保存先を出力します。

シミュレーター用のビルド例：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project 色々変え.xcodeproj -scheme 色々変え \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/iroirokae-build CODE_SIGNING_ALLOWED=NO build
```

`missing Metal Toolchain` が出る環境では、XcodeのComponentsからMetal Toolchainを追加するか、次を実行してください。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -downloadComponent MetalToolchain
```

実カメラの向き、解像度切り替え、露出、発熱、電池消費、映像全体の遅延はiPhone／iPad実機での確認が必要です。フレーム間隔は遅延の実測値ではありません。電池消費を比べる場合は、同じ端末・風景・画面輝度で「変換なし」と各変換方式を比較してください。

開発時には、Xcode 27.2でシミュレーター用Debugビルドと実機用Releaseビルド（署名なし）が成功しました。Apple M3のGPUで28,884件の画素検証を実施し、iPhone 17 Pro／iOS 26.5の操作テストで変換・強度、解像度・fps・表示範囲の保存、カメラが使えない場合の復帰を確認しました。iPad Pro 13インチ（M5）／iPadOS 26.5でも、比較画面と設定画面を表示して確認しています。
