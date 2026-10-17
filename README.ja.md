<div align="center">

<img src="assets/app-icon.png" width="128" alt="Spectre のアイコン">

# spectre-apple

**Spectre**：[ghost](https://github.com/jsaiko/ghost) リモートデスクトップの Mac、iPad、iPhone 向けネイティブクライアント

[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iPadOS%20%7C%20iOS%2027-lightgrey)](#動作環境)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | **日本語** | [Español](README.es.md)

</div>

![Mac 上の Spectre。Ubuntu ホストの GNOME デスクトップに接続しています](assets/macos-session.webp)

ghost はオープンソースのリモートデスクトップシステムです。ホスト（wraith）が GDP プロトコルで Linux のデスクトップを配信し、クライアントがそれを表示して入力を送り返します。spectre-apple はその Apple デバイス向けのクライアントで、ghost のプロトコルライブラリ libgdp の上に、Swift と SwiftUI、Metal、VideoToolbox で書かれています。

ghost プロジェクトの一部ではない、独立したサードパーティ製のクライアントです（[謝辞](#謝辞)をご覧ください）。

## 機能

**接続**

- ユーザ名とパスワードでサインインし、ワンタイムコードなどの追加の質問に答えたら、デバイスとデスクトップのセッションを選ぶか、実行中のセッションを引き継ぎます。
- 初回信頼（TOFU）：サーバーの証明書のフィンガープリントを一度確認すれば記憶されます。**信頼済みのサーバー…** で一覧・削除できます。
- パスワードをサーバーと一緒に保存しておけば、ワンタップで **接続** できます。キーチェーンに保存することもできます。
- 接続が切れても（Wi-Fi の切り替え、スリープ、iOS によるアプリの一時停止など）自動的に再接続します。

**映像と音声**

- H.264 と HEVC をハードウェアでデコードし、フレームをコピーせずに Metal で表示します。
- リモートデスクトップのサイズはウインドウや画面に合わせて変わります。Retina のフル解像度で動かすこともできます。
- Mac のフルスクリーンでは、ポインタが上端に来るまでツールバーとメニューバーを隠します。
- リモートの音声。ジッタバッファ付きで、消音ボタンもあります。

**入力**

- キーは物理的な位置で送られるため、入力される文字はリモート側のキーボード配列で決まります。
- マウスはすべてのボタンとスムーズスクロールに対応し、ゲームや 3D 向けに相対移動を送るキャプチャモードもあります。リモートのカーソルはローカルで描画します。
- iPad：ハードウェアキーボード、トラックパッド、マウスに加え、ダイレクトタッチとトラックパッドの 2 つのモードでの指の操作。
- iPhone と iPad：オンスクリーンキーボードと、矢印キー、Esc、Tab、押されたままになる修飾キー、Super+Tab のようなシステムの組み合わせを送れるキーバー。

**Mac**

- ホストを並べたホームウインドウ（各ホストに前回の画面）と、セッションごとのウインドウがあり、複数のセッションを同時に動かせます。
- クリップボード、マウスのキャプチャ、消音のツールバー。サブタイトルには往復の遅延とフレームレートが表示されます。
- マウスのキャプチャ、クリップボード、macOS が先に取ってしまうキーの組み合わせを送る **Session** メニュー。ショートカットは増やしていないので、キーはすべてリモートデスクトップに届きます。

**iPad と iPhone**

- リモートデスクトップが画面いっぱいに表示され、操作ボタンは Liquid Glass で画面の上に浮かび、両隅の 2 つのボタンにまとまります。
- プロンプトパネル：システムの入力方式、音声入力、ペーストで文章を書き、ホストのカーソル位置にまとめて送ります。
- 音声入力：マイクキーを押しながら話すと、デバイス上で文字になり、ホストで入力されます。
- ピンチで拡大でき、**画面いっぱいに表示** もあります。拡大した画面はポインタについていきます。
- 範囲の通知：ターミナルなど画面の一部を見張り、変化が止まったときや変化し始めたときに知らせます。

**そのほか**

- テキストのクリップボードの双方向同期（オンにするまでオフ）と、最大 4 台のゲームコントローラ。
- 切断（セッションは実行を続けます）とログアウト（セッションを終了します）。
- 英語、簡体字中国語、繁体字中国語、日本語、スペイン語。

**未実装：** 可逆の高画質化レイヤー、AV1 と PyroWave、マイクの音声をホストに送る機能（実装済みで、いまは無効）、iOS での認証局発行の証明書の検証。

## スクリーンショット

| Mac のホームウインドウ | iPad でのセッション |
|---|---|
| ![Mac のホームウインドウ。サイドバーにホスト、右に選んだホストの前回の画面と接続ボタン](assets/macos-home.webp) | ![iPad の画面に合わせたサイズの GNOME デスクトップ。右下のキーバーを開いたところ](assets/ipad-session.webp) |

## 動作環境

- Apple シリコン搭載で macOS 27 の Mac、または iOS / iPadOS 27 の iPhone・iPad
- ghost ホスト（ghostd と wraith）。構築方法は [ghost](https://github.com/jsaiko/ghost) をご覧ください

## インストール

Mac 版は公証済みの `.dmg` を [GitHub Releases](https://github.com/pokoblin/spectre-apple/releases/latest) からダウンロードし、Spectre を「アプリケーション」フォルダにドラッグしてください。iPhone と iPad ではソースからビルドします。

## 使い方

**+** でサーバーを追加します。アドレス（`host` または `host:port`。ポートの既定値は 4442）とユーザ名、必要ならパスワードを入力します。**接続** してデスクトップを選びます。最初の接続時には、サーバーの証明書のフィンガープリントを確認してください。

Mac ではセッションがそれぞれ専用のウインドウで開きます。閉じると切断し、ホストのデスクトップは動いたままです。iPad と iPhone ではセッションがホーム画面の上に重なります。

**Mac でのキーボード。** Cmd は Super として送られるため、リモートデスクトップでのコピー＆ペーストは Ctrl+C と Ctrl+V のままです。Mac 側に残るショートカットは次のものだけです：

| ショートカット | 動作 |
|---|---|
| Ctrl+Cmd+G | マウスのキャプチャと解除 |
| Ctrl+Cmd+F | フルスクリーン |
| Cmd+Q | 終了 |

**iPad と iPhone でのタッチ操作。** **その他 › 入力方式** で次のモードを切り替えます：

- **トラックパッド**（デフォルト）：1 本指でカーソルを動かし、タップでクリックします。
- **タッチ**：触れた位置にポインタが移動します。タップでクリック、長押しで右クリック、1 本指でドラッグ、2 本指でスクロール、2 本指または 3 本指のタップで右クリックまたは中クリックです。

## ソースからのビルド

Xcode 27（iOS 27 シミュレータのランタイムを含む）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、`cmake` 3.25 以降と `ninja`（`brew install cmake ninja`）、[vcpkg](https://github.com/microsoft/vcpkg) が必要です。vcpkg は上流の CI が使っているコミットに固定するのがおすすめです：

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

vcpkg をほかの場所に置く場合は `VCPKG_ROOT` を設定してください。

1. ghost サブモジュールごとクローンします。サブモジュールは当面、[pokoblin/ghost](https://github.com/pokoblin/ghost) フォーク（上流＋ファイル転送）を指しています。既存のクローンでは `git submodule sync && git submodule update --init` を実行します。

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

2. `GDPCore.xcframework`（libgdp とその依存ライブラリ、C ブリッジ）を `Packages/GDPKit/Artifacts/` にビルドします。初回は数分かかります。一部のスライスだけをビルドするには `macos`、`ios`、`ios-simulator` を指定します。

   ```bash
   scripts/build-gdpcore.sh
   ```

3. Xcode プロジェクトを生成し、`Spectre.xcodeproj` を開いて `Spectre` スキームを実行します：

   ```bash
   xcodegen generate
   ```

   または、コマンドラインで Mac アプリをビルドして「アプリケーション」フォルダにコピーします：

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

   ```bash
   ditto build/DerivedData/Build/Products/Release/Spectre.app /Applications/Spectre.app
   ```

iPhone や iPad で実行するには、Xcode でターゲットの開発チームを選んでください。

## 開発

### テスト

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

どちらのパッケージにもプロセス内のテストホストと lobby があり、エンドツーエンドのテストはループバック上の実際の QUIC で行います。iPad シミュレータで実行するには、各パッケージで `-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0'` を付けて `xcodebuild test` を実行します。

### サーバーなしで動かす

次のオプションを付けると、ログインを飛ばして生成した 1080p60 のテストストリームを再生し、統計を画面と stdout に出力します：

- `--source loopback`（既定）：アプリ内のテストホストが、127.0.0.1 上の実際の GDP セッションで送ります
- `--source direct`：ネットワークを通さず直接デコーダに渡します
- `--connect HOST:PORT --token TOKEN --fingerprint SHA256`：静的トークンで起動した wraith
- `--bench N`：N 秒間計測し、結果を出力して終了します

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

そのほか：`--codec h264|h265`、`--mode onArrival|displayLink`、`--in-flight N`、`--screen N`、`--rate HZ`、`--min-present-ms MS`、`--host-clipboard TEXT`。

iOS シミュレータでは：

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

シミュレータはソフトウェアでデコードするため、そこで計測した時間は実機とは比較できません。

### ディレクトリ構成

| パス | 内容 |
|---|---|
| `project.yml` | XcodeGen のプロジェクト。マルチプラットフォームのアプリターゲットが 1 つ |
| `App/` | アプリ本体：エントリポイント、ホーム画面、セッションの UI、iPad と iPhone の操作ボタン、アイコン |
| `Packages/GDPKit/` | libgdp への C ブリッジと、その Swift ラッパー |
| `Packages/SpectreKit/` | セッション、デコード、Metal での表示、入力、ログイン |
| `scripts/` | 依存ライブラリと xcframework をビルドするスクリプト |
| `third_party/ghost/` | ghost（サブモジュール、pokoblin/ghost フォーク）。ビルドするのは libgdp だけ |

## コントリビュート

Issue やプルリクエストを歓迎します。大きな変更の場合は、先に Issue を立ててください。

- クライアントのコードは、GDP の仕様（`third_party/ghost/docs/spec/gdp-spec.md`）と公開されている標準規格をもとに書いてください。上流の ghost の大部分は GPL-3.0 なので、そこからコードをコピーしたり移植したりしないでください（上流の spectre クライアントも含みます）。MIT なのは `libgdp/` と仕様だけです。
- 変更を送る前に両方のパッケージのテストを実行してください。
- 新しい UI の文言には、すべての言語の翻訳が必要です。`scripts/sync-strings.sh` で String Catalog を更新します。

## 謝辞

spectre-apple は、[Joseph Saiko](https://saiko.dev) さんの [ghost](https://github.com/jsaiko/ghost)（GDP プロトコル、ホストの wraith、Linux 向けクライアントの spectre）に触発されたプロジェクトです。ghost の libgdp を使い、ghost が公開している仕様と設計ドキュメントに従い、Spectre という名前も上流のクライアントから借りています。ghost をオープンソースで公開し、libgdp と仕様を MIT ライセンスで提供してくださった作者に深く感謝します。それがなければ、このプロジェクトは存在しませんでした。

## ライセンス

[MIT](LICENSE)。

- 上流の ghost では、`libgdp/` と仕様が MIT、それ以外はすべて GPL-3.0-only です。本プロジェクトがビルドするのは `libgdp/` だけで、GPL の部分からコードをコピーしたり移植したりはしていません。
- アプリは ngtcp2、OpenSSL、Protocol Buffers、Abseil、zstd（MIT、Apache-2.0、BSD-3-Clause）を静的にリンクしています。それらのライセンス表示は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) にあります。
