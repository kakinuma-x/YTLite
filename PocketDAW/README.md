# PocketDAW

iPhone 向けのマルチトラック DAW です（SwiftUI、iOS 17 以降）。
iPhone Duo の外側 5.4 インチ画面でも、開いた 7.6 インチ画面でも同じ 1 画面構成で使えるようにレイアウトしています。

## できること

- シンセ（7 プリセット＋波形・フィルター・ADSR）、ドラム（12 パーツ）、オーディオの 3 種類のトラック
- タイムラインでのクリップ移動・長さ変更・複製・分割、ループ再生、メトロノーム、カウントイン
- ピアノロール／ドラムグリッド（グリッド、クオンタイズ、ベロシティ、範囲選択）
- マルチタッチの鍵盤・パッドでのリアルタイム録音、マイク録音、音声ファイルの読み込み
- ミキサー（音量・パン・リバーブ・ディレイ・ミュート／ソロ・メーター）、マスターリミッター
- 取り消し／やり直し、自動保存、WAV 書き出し（共有シート）

## ビルド

`PocketDAW.xcodeproj` を Xcode 16 以降で開き、Signing & Capabilities で自分の Team を選んで実機に Run します。
外部ライブラリはありません。

GitHub Actions（`.github/workflows/pocketdaw.yml`）は音声コアのテストと未署名 IPA のビルドを行い、
IPA を成果物 `PocketDAW-unsigned-ipa` として残します。

## 構成

| 場所 | 役割 |
| --- | --- |
| `PocketDAW/Core/` | 音声コア。Foundation だけに依存（モデル、シーケンサー、シンセ／ドラム、ミキサー、書き出し） |
| `PocketDAW/Audio/AudioHost.swift` | AVAudioEngine との接続、マイク入力、音声ファイルのデコード |
| `PocketDAW/Store.swift` | アプリの状態、編集操作、取り消し履歴、保存 |
| `PocketDAW/Views/` | SwiftUI の画面とタッチ処理 |
| `Package.swift`, `Tests/` | 音声コアを `swift test` で検証するためのパッケージ |

再生も書き出しも同じ `DAWEngine.render` を通るので、書き出した WAV は再生時と同じ音になります。

## 制限

- MIDI キーボード入力、Audio Unit プラグインは未対応
- オーディオのタイムストレッチはなし（テンポを変えても録音の長さは変わりません）
- 曲データはアプリ内に保存されます。別端末への移行機能はありません
