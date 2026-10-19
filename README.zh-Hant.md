<div align="center">

<img src="assets/app-icon.png" width="128" alt="Spectre 圖示">

# spectre-apple

**Spectre**：[ghost](https://github.com/jsaiko/ghost) 遠端桌面在 Mac、iPad 和 iPhone 上的原生用戶端

[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iPadOS%20%7C%20iOS%2027-lightgrey)](#執行需求)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) | [简体中文](README.zh-Hans.md) | **繁體中文** | [日本語](README.ja.md) | [Español](README.es.md)

</div>

![Mac 上的 Spectre，連線到 Ubuntu 主機上的 GNOME 桌面](assets/macos-session.webp)

ghost 是一套開源的遠端桌面系統：主機端（wraith）透過 GDP 協定傳送 Linux 桌面，用戶端負責顯示畫面並將輸入傳回。spectre-apple 就是 Apple 裝置上的這個用戶端，以 Swift 搭配 SwiftUI、Metal 和 VideoToolbox 撰寫，底層使用 ghost 的協定函式庫 libgdp。

它是獨立的第三方用戶端，並非 ghost 專案的一部分（詳見[致謝](#致謝)）。

## 功能

**連線**

- 以使用者名稱和密碼登入，回答伺服器後續的提問（例如一次性驗證碼），接著選擇裝置和桌面工作階段，或接管一個正在執行的工作階段。
- 首次信任（TOFU）：確認一次伺服器的憑證指紋，之後就會記住；**信任的伺服器…** 會列出記住的指紋，也可以刪除（Mac 上在 **設定 › 伺服器**）。
- 將密碼和伺服器一起儲存，點一下 **連線** 就能登入，也可以存進鑰匙圈。
- 連線中斷時（切換 Wi-Fi、進入睡眠、iOS 暫停 App）會自動重新連線。
- 中斷連線（桌面工作階段繼續執行）或登出（結束工作階段）。

**畫面與聲音**

- H.264、HEVC 和 AV1 由硬體解碼，交給 Metal 顯示，全程不複製影格。在能以硬體解碼 AV1 的裝置上（Apple M3、A17 Pro 及以後）會優先要求 AV1，主機的顯示卡能編碼 AV1 時就使用它，否則使用 HEVC。
- 無損增強：畫面上停止變化的區域，主機會再以無損方式傳送一次，疊在視訊上逐像素精確顯示，文字和線條因此非常清晰。預設開啟；**更多 › 無損增強**（Mac 上還有 **設定 › 畫面**）可以關閉，減輕主機的負擔。
- 有線網路上的 PyroWave：主機和本機在同一個 1 Gbit/s 以上的有線網路中時，會優先要求 PyroWave。它是只做影格內編碼的小波編解碼器，幾百 Mbit/s 時看起來接近無損，在 GPU 上解碼一個影格約 1 毫秒。透過 Wi-Fi、較慢的連結或其他網路連線時，照常使用一般的編解碼器。主機需要啟用 PyroWave，GPU 也要夠快：小型內建顯示卡在高解析度下可能跟不上（Intel N100 在 2560×1496 下約 25 fps）。**更多 › 有線網路使用 PyroWave**（Mac 上還有 **設定 › 畫面**）可以關閉，並顯示目前是否在用、沒用的原因。
- 遠端桌面的大小會跟隨視窗或螢幕，也可以以 Retina 的完整解析度執行。
- Mac 上全螢幕時會隱藏工具列和選單列，指標移到頂端邊緣時才出現。
- 遠端桌面的聲音，具備抖動緩衝和靜音按鈕。

**輸入**

- 按鍵依實體位置傳送，因此打出哪個字元由遠端的鍵盤配置決定。
- 滑鼠支援所有按鍵和平滑捲動，另有傳送相對位移的擷取模式，適合遊戲和 3D；遠端游標在本機繪製。
- iPad 上：支援實體鍵盤、觸控式軌跡板和滑鼠，觸控則可使用「直接觸控」或「觸控式軌跡板」兩種模式。
- iPhone 和 iPad 上：螢幕鍵盤，加上一條按鍵列，提供方向鍵、Esc、Tab、按下後保持的修飾鍵，以及 Super+Tab 這類系統組合鍵。
- 最多支援四個遊戲控制器。

**剪貼簿與檔案**

- 雙向同步文字剪貼簿，預設關閉，需要時再開啟。
- Mac 上可以雙向拷貝貼上檔案和檔案夾：在 Finder 中拷貝、到遠端桌面貼上，或在遠端桌面拷貝、到 Finder 中貼上（一次不超過 100 MB；更大的拷貝會提示下載）。
- iPad 上在「檔案」App 中拷貝的檔案和檔案夾，也可以貼到遠端桌面。
- 將檔案傳送到主機：拖到畫面上，或使用 **傳送檔案⋯**。檔案存進主機使用者的下載檔案夾，不會覆寫既有的檔案，Spectre 會告訴你存到了哪個檔案夾。
- 下載主機上拷貝的檔案和檔案夾：Mac 上存到「下載項目」檔案夾，iPad 和 iPhone 上存到「檔案」App 中 Spectre 的檔案夾。
- 將一個檔案夾唯讀共享給主機：它會出現在主機的檔案管理器中，名稱後面標著裝置的名稱。
- 傳輸列表會顯示進度、可以取消，也列出結果。需要主機支援檔案傳輸，請見 [執行需求](#執行需求)。

**Mac 上**

- 主機列表首頁視窗，每台主機顯示上次的畫面；每個工作階段各開一個視窗，可以同時連線好幾台。
- 工具列放著 **檔案** 選單、傳輸列表、共享剪貼簿、擷取滑鼠和靜音，副標題顯示往返延遲和影格速率。
- **Session** 選單：檔案、共享檔案夾、擷取滑鼠、剪貼簿，以及被 macOS 自己攔下的組合鍵。沒有新增快速鍵，工作階段視窗裡所有按鍵都能傳給遠端桌面。
- **設定**（Spectre › 設定…，或在工作階段視窗以外按 Cmd+,）：全螢幕、剪貼簿、聲音、解析度、無損增強、PyroWave 和遊戲控制器的預設設定，以及信任的伺服器。在這裡更改的設定也會套用到已開啟的工作階段。

**iPad 和 iPhone 上**

- 遠端畫面鋪滿整個螢幕，控制項以 Liquid Glass 浮在上面，平時收成兩角的圓鈕。
- 提示詞面板：用系統的輸入法、聽寫或貼上寫好一段文字，一次送到主機的游標處。
- 語音輸入：按住麥克風鍵說話，說的話在本機轉成文字，輸入到主機上。
- 雙指捏合縮放畫面，或用**填滿螢幕**；放大後畫面會跟著指標移動。
- 區域提醒：盯著畫面上的一塊區域（例如終端機），它停止變化或開始變化時提醒你。

**語言：** 英文、簡體中文、繁體中文、日文和西班牙文。

**尚未完成：** 將你的麥克風傳送到主機（已經寫好，暫時停用），以及在 iOS 上驗證憑證授權單位簽發的憑證。

## 螢幕截圖

| Mac 上的首頁視窗 | iPad 上的工作階段 |
|---|---|
| ![Mac 上的首頁視窗：側邊欄是主機，右邊是所選主機的上次畫面和連線按鈕](assets/macos-home.webp) | ![iPad 上的 GNOME 桌面，大小跟隨 iPad 螢幕，右下角的按鍵列已展開](assets/ipad-session.webp) |

## 執行需求

- 搭載 Apple 晶片、執行 macOS 27 的 Mac，或執行 iOS / iPadOS 27 的 iPhone、iPad
- 一台 ghost 主機（ghostd 和 wraith），架設方式請見 [ghost](https://github.com/jsaiko/ghost)
- 檔案傳輸需要較新的 ghost（2026 年 10 月以後的上游 `main`）。在遠端桌面貼上本機拷貝的檔案、共享檔案夾，還需要 wraith 以 libfuse3 3.12 或更新版本建置（建置前 `apt install libfuse3-dev`），主機上要有 `/dev/fuse` 和 `fusermount3`：主機會把 Spectre 提供的檔案掛載起來。沒有這些時，傳送和下載照樣能用。
- PyroWave 需要以 libpyrowave 建置的 wraith（ghost 的 `packaging/build-pyrowave.sh`，它固定了兩端必須一致的版本），並在 `/etc/ghost/wraith.toml` 的 `[encode.codecs]` 中設定 `pyrowave = true`。

## 安裝

Mac 版請從 [GitHub Releases](https://github.com/pokoblin/spectre-apple/releases/latest) 下載經過公證的 `.dmg`，把 Spectre 拖到「應用程式」檔案夾即可。iPhone 和 iPad 版請從原始碼建置。

## 使用方式

用 **+** 新增伺服器：位址（`host` 或 `host:port`，連接埠預設 4442）、你的使用者名稱，也可以填寫密碼。然後點 **連線**，選擇一個桌面。第一次連線時，請確認伺服器的憑證指紋。

Mac 上每個工作階段各開一個視窗；關閉它就會中斷連線，主機上的桌面繼續執行。iPad 和 iPhone 上工作階段蓋在首頁上面。

**檔案。** Mac 上全部在工具列的 **檔案** 選單和 **Session** 選單中；iPad 和 iPhone 上在 **更多 › 檔案** 中。

- **拷貝貼上**（Mac，開啟共享剪貼簿時）：在 Finder 中拷貝的檔案和檔案夾可以貼到遠端桌面，主機在貼上過程中從 Mac 讀取它們，所以貼上完成前請保持 Spectre 開啟；傳輸列表會顯示進度，也可以停止。在主機上拷貝的檔案和檔案夾，總共不超過 100 MB 時會放進 Mac 的剪貼簿，在 Finder 中 **貼上** 就是檔案本身。
- **拷貝貼上**（iPad，開啟共享剪貼簿時）：在「檔案」App 中拷貝的檔案和檔案夾可以貼到遠端桌面。每次 iPadOS 都會先詢問是否允許 Spectre 讀取，除非你在 **設定 › App › Spectre › 從其他 App 貼上** 中選了 **允許**（Spectre 會提醒一次）。iPadOS 給 App 的是一份拷貝而不是原檔案：Spectre 會保留這份拷貝，直到主機取完，所以拷貝大檔案要花點時間、佔些空間。主機貼上時請讓 Spectre 留在前景。
- **傳送檔案⋯**，或將檔案拖到畫面上：主機將檔案存進使用者的下載檔案夾（`~/Downloads`，或 wraith.toml 中 `[files] directory` 指定的檔案夾），名稱已被使用時存成「name (1).ext」。檔案夾請用拷貝貼上。
- **下載**：主機使用者拷貝檔案或檔案夾時，Spectre 會提示下載，Mac 上存到「下載項目」檔案夾，iPad 和 iPhone 上存到「檔案」App 中 Spectre 的檔案夾。
- **共享檔案夾⋯**：主機能看到這個檔案夾，唯讀、不含隱藏檔案，直到你停止共享（同一選單中的 **停止共享**，或在傳輸列表中）或結束 Spectre。工作階段重新連線後會自動再次共享；停止過的可以用 **重新共享** 找回來。iPad 和 iPhone 上在「檔案」App 中選擇檔案夾：本機的、iCloud 雲碟中的，或其他 App 的都可以。

**Mac 上的鍵盤。** Cmd 以 Super 鍵傳送，因此在遠端桌面上拷貝貼上仍是 Ctrl+C 和 Ctrl+V。只有下列快速鍵留在本機：

| 快速鍵 | 作用 |
|---|---|
| Ctrl+Cmd+G | 擷取或釋放滑鼠 |
| Ctrl+Cmd+F | 全螢幕 |
| Cmd+Q | 結束 |

**iPad 和 iPhone 上的觸控。** 以 **更多 › 輸入方式** 切換：

- **觸控式軌跡板**（預設）：單指移動游標，點一下即按一下。
- **觸控**：指標跟著手指移動。點一下是按一下，長按是右鍵，單指拖移是拖曳，雙指拖移是捲動，雙指或三指點一下是右鍵或中鍵。

## 從原始碼建置

需要 Xcode 27 和 iOS 27 模擬器執行環境、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、`cmake` 3.25 以上和 `ninja`（`brew install cmake ninja`），以及 [vcpkg](https://github.com/microsoft/vcpkg)，最好固定在上游 CI 使用的提交：

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

如果 vcpkg 放在其他位置，請設定 `VCPKG_ROOT`。

1. 複製儲存庫，連同 ghost 子模組一起，子模組跟隨 [pokoblin/ghost](https://github.com/pokoblin/ghost) fork 的 `main`（與上游一致）。已有的複製中執行 `git submodule sync && git submodule update --init`。

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

2. 建置 `GDPCore.xcframework`（libgdp、它的相依套件和一層 C 橋接），產物寫入 `Packages/GDPKit/Artifacts/`。第一次建置需要幾分鐘；寫上 `macos`、`ios` 或 `ios-simulator` 就只建置這些 slice。

   ```bash
   scripts/build-gdpcore.sh
   ```

   接著建置 `PyroWave.xcframework`（PyroWave 編解碼器的 Metal 版，來自 `third_party/pyrowave` 子模組），產物寫入 `Packages/SpectreKit/Artifacts/`，幾秒鐘就好。

   ```bash
   scripts/build-pyrowave.sh
   ```

3. 產生 Xcode 專案，接著打開 `Spectre.xcodeproj`，執行 `Spectre` scheme：

   ```bash
   xcodegen generate
   ```

   也可以在命令列建置 Mac App，再將它複製到「應用程式」檔案夾：

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

   ```bash
   ditto build/DerivedData/Build/Products/Release/Spectre.app /Applications/Spectre.app
   ```

要在 iPhone 或 iPad 上執行，請在 Xcode 中為 target 選擇你的開發團隊。

## 開發

### 測試

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

兩個套件都內建行程內的測試主機和測試 lobby，因此端對端測試走的是本機迴路上真實的 QUIC 連線。要在 iPad 模擬器上測試，請在各個套件中執行 `xcodebuild test`，加上 `-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0'`。

### 不連伺服器執行

下列參數會略過登入，播放一段產生出來的 1080p60 測試串流，統計資料顯示在畫面上，同時輸出到 stdout：

- `--source loopback`（預設）：App 內的測試主機，透過 127.0.0.1 上真實的 GDP 工作階段傳送
- `--source direct`：直接送進解碼器，不經過網路
- `--connect HOST:PORT --token TOKEN --fingerprint SHA256`：以靜態 token 啟動的 wraith
- `--bench N`：量測 N 秒，輸出結果後結束

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

其他參數：`--codec h264|h265|av1|pyrowave`（AV1 播放內建的測試串流，需要硬體解碼；PyroWave 的測試串流由它的 Metal 版即時編碼，約 250 Mbit/s）、`--mode onArrival|displayLink`、`--in-flight N`、`--screen N`、`--rate HZ`、`--min-present-ms MS`、`--host-clipboard TEXT`。

以回送主機測試檔案傳輸：`--send-file PATH` 在工作階段開始後傳送一個檔案，`--host-file PATH` 讓測試主機的使用者拷貝一個檔案，也可以是檔案夾（這兩個參數都可以給多次），`--download-copied` 下載每一次拷貝的檔案，`--download-dir DIR` 把下載存到 `DIR`。`--host-fetch-copied` 讓測試主機像貼上那樣讀取本機拷貝的每個檔案，`--share-folder DIR` 在工作階段開始後共享一個檔案夾；測試主機會印出收到的內容，並列出每個共享。

在 iOS 模擬器中：

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

模擬器是軟體解碼，因此在模擬器中量到的耗時無法和實機比較。

### 目錄結構

| 路徑 | 內容 |
|---|---|
| `project.yml` | XcodeGen 專案：一個多平台 App target |
| `App/` | App 本身：進入點、首頁、工作階段介面、檔案傳輸介面、iPad 和 iPhone 的控制項、圖示 |
| `Packages/GDPKit/` | 通往 libgdp 的 C 橋接及其 Swift 封裝 |
| `Packages/SpectreKit/` | 工作階段、解碼、Metal 顯示、輸入、剪貼簿、檔案傳輸、登入 |
| `scripts/` | 建置相依套件和 xcframework |
| `third_party/ghost/` | ghost 子模組（跟隨上游的 pokoblin/ghost fork `main`），只編譯其中的 libgdp |
| `third_party/pyrowave/` | PyroWave 子模組，只編譯其中的 Metal 版（`metal/`） |

## 參與貢獻

歡迎提交 issue 和 pull request；較大的改動請先開 issue 討論。

- 用戶端程式碼依照 GDP 規格（`third_party/ghost/docs/spec/gdp-spec.md`）和公開標準撰寫。上游 ghost 大部分的程式碼採用 GPL-3.0，請不要複製或移植其中的程式碼，包括它的 spectre 用戶端；只有 `libgdp/` 和協定規格採用 MIT。
- 提交改動前請跑過兩個套件的測試。
- 新的介面文字需要補齊所有語言的翻譯；`scripts/sync-strings.sh` 會更新 String Catalog。

## 致謝

spectre-apple 的靈感來自 [Joseph Saiko](https://saiko.dev) 的 [ghost](https://github.com/jsaiko/ghost)：GDP 協定、主機端 wraith 和 Linux 用戶端 spectre。本專案使用 ghost 的 libgdp，依照它公開的協定規格和設計文件撰寫，名稱也沿用上游用戶端的 Spectre。非常感謝原作者將 ghost 開源，並以 MIT 授權開放 libgdp 和協定規格；沒有它們就沒有這個專案。

App 裡也有這段致謝，在「關於 Spectre」中：Mac 上在 App 選單裡，iPad 和 iPhone 上在伺服器列表上方的「⋯」選單裡。

## 授權

[MIT](LICENSE)。

- 上游 ghost 中，`libgdp/` 和協定規格採用 MIT 授權，其餘部分採用 GPL-3.0-only。本專案只編譯 `libgdp/`，沒有任何程式碼複製或移植自 GPL 部分。
- App 靜態連結了 ngtcp2、OpenSSL、Protocol Buffers、Abseil、zstd 和 PyroWave（MIT、Apache-2.0、BSD-3-Clause），它們的授權聲明見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
