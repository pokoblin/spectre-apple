# spectre-apple

[English](README.md) | [简体中文](README.zh-Hans.md) | **繁體中文** | [Español](README.es.md)

[ghost](https://github.com/jsaiko/ghost) 遠端桌面的 Apple 原生用戶端，支援 macOS、iPadOS 和 iOS（僅支援 Apple 晶片／arm64）。App 顯示名稱為 **Spectre**，Bundle ID 為 `org.ghost.spectre.apple`。

> **致謝**：本專案的靈感來自 [Joseph Saiko](https://saiko.dev) 的 [ghost](https://github.com/jsaiko/ghost)。ghost 是一套完整的遠端桌面系統，包含 GDP 協定、主機端 wraith 和 Linux 用戶端 spectre。spectre-apple 讓 Apple 裝置也能連上 ghost：它使用 ghost 的協定函式庫 libgdp，依照 ghost 公開的協定規格和設計文件撰寫，名稱也沿用上游用戶端的 Spectre。感謝原作者將 ghost 開源，並以 MIT 授權開放 libgdp 和協定規格，這個專案才得以實現。本專案是獨立的第三方用戶端，並非 ghost 官方專案。

![iPad 上的連線階段：觸控板模式，由 Metal 繪製的遠端游標](docs/images/ipad-trackpad-mode.jpg)

- **協定層**：上游的 C++ libgdp（QUIC：ngtcp2 + OpenSSL；protobuf；zstd），編譯成靜態函式庫並封裝為 xcframework，透過一層 C ABI 提供給 Swift 使用。
- **平台層**：Swift 6、SwiftUI、Metal、VideoToolbox。連線階段、登入和輸入的用戶端邏輯都依照 GDP 規格（`third_party/ghost/docs/spec/gdp-spec.md`）自行實作。

[`docs/`](docs/) 下的設計說明和實測紀錄以簡體中文撰寫。

## 現況

已經可用：

- **登入**：lobby 登入（§4、§5），首次連線時確認並記住伺服器憑證（TOFU），依伺服器的提示進行互動式驗證，選擇裝置和桌面工作階段，接管既有的工作階段。見 [docs/login.md](docs/login.md)。
- **視訊**：H.264／HEVC，由 VideoToolbox 硬體解碼，零複製交給 Metal 顯示；向主機回報影格遺失和延遲統計（StatsReport）。見 [docs/session-client.md](docs/session-client.md)、[docs/prototype-findings.md](docs/prototype-findings.md)。
- **輸入**：鍵盤按實體按鍵位置轉送；滑鼠支援絕對座標、各個按鍵和平滑捲動，也可以擷取滑鼠以傳送相對移動；在本機繪製遠端游標；iPad 支援實體鍵盤、觸控板和滑鼠，手指可以選擇「直接觸控」或「觸控板」兩種用法。見 [docs/input.md](docs/input.md)。
- **音訊**：播放遠端桌面的聲音（Opus，使用系統內建的解碼器），60 ms 的抖動緩衝，遺失封包時加以補償；工具列可以靜音。開啟麥克風後會把它傳給遠端桌面。見 [docs/audio.md](docs/audio.md)。
- **剪貼簿**：文字雙向同步（§7.9），預設關閉，在工具列中開啟。Mac 上在 Spectre 處於使用中時傳送拷貝的內容；iPad 上用貼上按鈕傳送，不會跳出系統的貼上提示，也可以選擇自動傳送。見 [docs/clipboard.md](docs/clipboard.md)。
- **遊戲控制器**：最多 4 個控制器以標準控制器轉送（§8.5），包括 Home 和 Share 鍵；預設關閉，在工具列中開啟。見 [docs/gamepad.md](docs/gamepad.md)。
- **工作階段控制**：中斷連線（遠端工作階段會保留）、登出（結束遠端工作階段）。

尚未完成：無損細化層（refine）、螢幕鍵盤、AV1／PyroWave。

## 建置

### 所需工具

- Xcode 27（含 iOS 27 模擬器執行環境）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `cmake`（3.25 以上）和 `ninja`：`brew install cmake ninja`
- [vcpkg](https://github.com/microsoft/vcpkg)，建議固定在上游 CI 使用的提交：

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

如果 vcpkg 不在 `~/src/vcpkg`，請在執行下列指令前設定 `VCPKG_ROOT`。

### 步驟

1. 取得程式碼（包含上游 ghost 的 submodule）：

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

   已經複製過的話，用 `git submodule update --init` 補上 submodule。

2. 編譯 `GDPCore.xcframework`：將 libgdp 和它的相依套件（vcpkg 靜態函式庫）加上 C 橋接層，合併成 `Packages/GDPKit/Artifacts/GDPCore.xcframework`（不納入 git）。第一次編譯相依套件需要幾分鐘，之後會使用 vcpkg 的二進位快取。記錄檔在 `build/logs/`。

   ```bash
   scripts/build-gdpcore.sh
   ```

   預設會編譯 `macos`、`ios`、`ios-simulator` 三個平台，也可以只指定其中幾個，例如 `scripts/build-gdpcore.sh macos`。

3. 產生 Xcode 專案，打開 `Spectre.xcodeproj`，選擇 `Spectre` scheme 執行：

   ```bash
   xcodegen generate
   ```

   也可以在命令列編譯 macOS 版：

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

要在實體裝置上執行，需在 Xcode 中為 target 選擇一個開發者 Team。

## 使用方式

App 啟動後是登入畫面：輸入伺服器（`host[:port]`，預設連接埠 4442）和使用者名稱，依伺服器的提示登入，選擇桌面後進入工作階段。首次連線時會先請你確認伺服器的憑證指紋。

**沒有伺服器？**點選 **Try the demo host**（使用者 demo，密碼 demo）：App 會在內部啟動一個測試 lobby 和測試主機，走完完整的登入和工作階段流程，畫面是測試串流，統計覆蓋層會顯示主機收到的輸入。

**鍵盤和滑鼠**：按鍵依實體位置轉送，由遠端的鍵盤配置決定輸入哪個字元；Cmd 會作為 Super（Windows 鍵）轉送，所以遠端的複製、貼上仍然是 Ctrl+C、Ctrl+V。只有下列三個快速鍵保留在本機：

| 快速鍵 | 作用 |
|---|---|
| Ctrl+Cmd+G | 擷取或釋放滑鼠（遊戲、3D 檢視使用相對移動），工具列上也有 Capture Mouse 按鈕 |
| Ctrl+Cmd+F | 全螢幕 |
| Cmd+Q | 結束 |

**iPad 和 iPhone 上的手指操作**：用工具列按鈕在兩種模式間切換。

- **Touch**：點在哪裡，指標就在哪裡。輕點是左鍵，長按是右鍵，單指拖曳是左鍵拖曳，雙指拖曳是捲動，雙指或三指輕點是右鍵或中鍵。
- **Trackpad**：把螢幕當觸控板使用，單指移動游標，輕點即點按。

**聲音**：主機傳送聲音時就會播放（wraith 能擷取到工作階段的音訊時就會傳送）。工具列的 **Mute** 按鈕只讓本機靜音，設定會被記住。demo 和 loopback 的測試主機每秒響一聲提示音。

**麥克風**：工具列的 **Microphone** 按鈕把本機麥克風傳給遠端桌面，遠端會把它當作工作階段預設的錄音裝置。每個工作階段開始時都是關閉的；第一次開啟時系統會要求權限。關閉就釋放裝置。還沒有做回音消除，請戴耳機，否則遠端會聽到自己的聲音。

## 開發

### 測試

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

兩個套件裡都有一個在行程內執行的測試主機（以及測試 lobby），透過真實的 QUIC 回送連線進行端對端測試。SpectreKit 的測試還包括 H.264／HEVC 彩條的色彩驗證和 Metal 繪製測試。在 iPad 模擬器上執行：

```bash
(cd Packages/GDPKit && xcodebuild test -scheme GDPKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-GDPKit)
```

```bash
(cd Packages/SpectreKit && xcodebuild test -scheme SpectreKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-SpectreKit)
```

### 略過登入的開發模式

帶任一下列命令列參數啟動時，App 會略過登入、直接播放。它會先用 VideoToolbox 即時編碼一段 10 秒的 1080p60 測試串流（約 3 秒），然後循環播放；左上角每秒更新一次解碼、顯示和工作階段的統計，stdout 也會印出相同的內容。工具列可以切換來源、H.264／HEVC 和呈現節奏。來源有三種：

- **Loopback**（預設）：App 內的測試主機透過真實的 GDP 工作階段（QUIC，127.0.0.1）傳送測試串流。
- **Direct**：測試串流直接交給解碼器，不經過網路。
- **Remote**：連線到一個以靜態 token 啟動的 wraith（§6.11）：

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --connect HOST:PORT --token TOKEN --fingerprint SHA256
```

效能量測模式：暖機 2 秒後量測 N 秒，印出統計後結束。

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

其他參數：`--source loopback|direct`、`--codec h264|h265`、`--mode onArrival|displayLink`、`--in-flight <N，0 表示不限>`、`--screen <螢幕編號>`、`--rate <display link Hz>`、`--min-present-ms <ms>`、`--host-clipboard <文字>`（loopback host 一開始的剪貼簿內容）。

### iOS／iPadOS 模擬器

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

iOS 的進入點是 UIKit 的 app delegate，這樣根 view controller 才能鎖定指標，見 [docs/input.md](docs/input.md)。如果之前安裝過舊版本（SwiftUI 進入點），需要先解除安裝一次（`xcrun simctl uninstall booted org.ghost.spectre.apple`），否則系統還原舊視窗時會是一片黑畫面。

在模擬器中 VideoToolbox 是軟體解碼，而且沒有 `presentedTime`，所以模擬器上的耗時數字不能和實體裝置或 macOS 比較。

### 目錄結構

| 路徑 | 內容 |
|---|---|
| `project.yml` | XcodeGen 專案定義（一個 macOS + iOS 多平台 App target） |
| `App/` | 各平台的進入點和介面（登入、工作階段） |
| `Packages/GDPKit/` | libgdp 的 C 橋接層（`Native/`）和 Swift 封裝：工作階段、lobby、測試主機 |
| `Packages/SpectreKit/` | 共用程式碼：工作階段、VideoToolbox 解碼、Metal 顯示、輸入、登入流程 |
| `scripts/` | 編譯相依套件、產生 xcframework 的指令碼 |
| `docs/` | 設計說明和實測紀錄（簡體中文） |
| `experiments/` | 一次性的實驗（如 Swift/C++ interop probe），不參與 App 建置 |
| `third_party/ghost/` | 上游 ghost（git submodule，唯讀） |

### 文件

- [docs/prototype-findings.md](docs/prototype-findings.md)：原型階段的三項技術風險和驗證結論（Swift 呼叫 libgdp、零複製顯示、iOS 交叉編譯）
- [docs/session-client.md](docs/session-client.md)：工作階段層，對照規格 §6–§11
- [docs/login.md](docs/login.md)：lobby 登入、憑證信任、demo
- [docs/input.md](docs/input.md)：鍵盤、滑鼠、游標、觸控
- [docs/audio.md](docs/audio.md)：音訊、抖動緩衝、Opus 解碼
- [docs/clipboard.md](docs/clipboard.md)：Mac 和 iPad 上的剪貼簿、回聲抑制、貼上提示
- [docs/gamepad.md](docs/gamepad.md)：遊戲控制器、按鍵對應、Home 鍵

## 授權

[MIT](LICENSE)。

- 上游 ghost 中，`libgdp/` 和協定規格採用 MIT 授權，其餘部分（包括上游自己的 spectre 用戶端）採用 GPL-3.0-only。本專案只編譯 `libgdp/`，用戶端程式碼依照規格和公開標準自行撰寫，沒有複製或移植 GPL 部分的程式碼。
- 編譯出的 App 靜態連結了 ngtcp2、OpenSSL、Protocol Buffers、Abseil、zstd，它們都採用寬鬆授權（MIT、Apache-2.0、BSD-3-Clause）。散布二進位檔時需附上它們的授權聲明，見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
