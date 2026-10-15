<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="Spectre 圖示">

# spectre-apple

**Spectre**：[ghost](https://github.com/jsaiko/ghost) 遠端桌面在 Mac、iPad 和 iPhone 上的原生用戶端

[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iPadOS%20%7C%20iOS%2027-lightgrey)](#執行需求)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) | [简体中文](README.zh-Hans.md) | **繁體中文** | [日本語](README.ja.md) | [Español](README.es.md)

</div>

![Mac 上的 Spectre，連線到 Ubuntu 主機上的 GNOME 桌面](docs/images/macos-session.webp)

ghost 是一套開源的遠端桌面系統：主機端（wraith）透過 GDP 協定傳送 Linux 桌面，用戶端負責顯示畫面並將輸入傳回。spectre-apple 將這個用戶端帶到 Apple 裝置上：一個以 Swift、SwiftUI、Metal 和 VideoToolbox 撰寫的原生 App，底層使用 ghost 自己的協定函式庫 libgdp。

spectre-apple 是受 ghost 啟發的獨立第三方用戶端，並非 ghost 官方專案。詳見[致謝](#致謝)。

## 功能

**登入**

- 以使用者名稱和密碼登入 ghost 伺服器；伺服器後續的提問（例如一次性驗證碼）會依序詢問。接著選擇裝置和桌面工作階段，或接管一個正在執行的工作階段。
- 首次信任（TOFU）：第一次連線時確認伺服器的憑證指紋，之後會記住。登入畫面的 **信任的伺服器…** 會列出記住的指紋，也可以刪除。
- 勾選 **記住**，登入資訊會儲存在鑰匙圈中，只留在本機；之後點一下最近的登入即可連線。
- 連線中斷時（切換 Wi-Fi、Mac 進入睡眠、iOS 暫停 App）會自動重新連線。

**畫面與聲音**

- H.264 和 HEVC 由 VideoToolbox 硬體解碼，交給 Metal 顯示，全程不複製影格；掉格和延遲統計會回報給主機。
- 遠端桌面的聲音，具備能掩蓋封包遺失的抖動緩衝，並可靜音。
- 開啟麥克風後，將本機麥克風傳送到遠端桌面。

**輸入**

- 按鍵依實體位置傳送，因此打出哪個字元由遠端的鍵盤配置決定。
- 滑鼠支援所有按鍵和平滑捲動，另有傳送相對位移的擷取模式，適合遊戲和 3D 檢視。遠端游標在本機繪製。
- iPad 上：支援實體鍵盤、觸控式軌跡板和滑鼠；手指可使用「直接觸控」或「觸控式軌跡板」兩種模式。
- iPhone 和 iPad 上：以螢幕鍵盤在遠端桌面上打字，並有一排按鍵列，提供 Esc、Tab、輔助鍵、方向鍵和功能鍵。

**共享**

- 雙向同步文字剪貼簿，預設關閉，需要時再開啟。
- 最多四個遊戲控制器，以標準控制器的形式轉送。

**其他**

- 中斷連線（遠端工作階段繼續執行）或登出（結束遠端工作階段）。
- 介面支援英文、簡體中文、繁體中文、日文和西班牙文，跟隨系統語言。

### 開發藍圖

尚未完成：

- 無損增強層（refine），以及 AV1 和 PyroWave 編碼
- 麥克風的回音消除
- 在 iOS 上驗證憑證授權單位簽發的憑證（目前和其他憑證一樣以首次信任處理）

## 螢幕截圖

| 在 Mac 上登入 | iPad 的觸控式軌跡板模式 |
|---|---|
| ![Mac 上的登入畫面](docs/images/macos-login.webp) | ![iPad 上觸控式軌跡板模式的工作階段，遠端游標由 Metal 繪製](docs/images/ipad-trackpad-mode.jpg) |

## 執行需求

- 搭載 Apple 晶片、執行 macOS 27 的 Mac，或執行 iOS / iPadOS 27 的 iPhone、iPad（僅支援 arm64）
- 一台可連線的 ghost 主機（ghostd 和 wraith），架設方式請見 [ghost](https://github.com/jsaiko/ghost) 專案

## 快速上手

Mac 版可以在 [GitHub Releases](https://github.com/pokoblin/spectre-apple/releases/latest) 下載：下載 `.dmg`，打開後把 Spectre 拖到「應用程式」檔案夾即可。App 使用 Developer ID 簽署，並經過 Apple 公證。

iPhone 和 iPad 版，或是想參與開發，請依照下面的步驟從原始碼建置。

### 工具

- Xcode 27，以及 iOS 27 模擬器執行環境
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `cmake`（3.25 或更新版本）和 `ninja`：`brew install cmake ninja`
- [vcpkg](https://github.com/microsoft/vcpkg)，最好固定在上游 CI 使用的提交：

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

如果 vcpkg 不在 `~/src/vcpkg`，請設定 `VCPKG_ROOT`。

### 建置

1. 複製儲存庫，連同上游 ghost 子模組一起（已有的複本中執行 `git submodule update --init`）：

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

2. 建置 `GDPCore.xcframework`，內含 libgdp、它的相依套件和一層很薄的 C 橋接。產物寫入 `Packages/GDPKit/Artifacts/`，不提交到儲存庫。第一次建置需要幾分鐘，之後會重複使用 vcpkg 的二進位快取。記錄檔在 `build/logs/`。

   ```bash
   scripts/build-gdpcore.sh
   ```

   預設建置 `macos`、`ios` 和 `ios-simulator` 三個 slice；只需要其中幾個時寫上名稱，例如 `scripts/build-gdpcore.sh macos`。

3. 產生 Xcode 專案，接著打開 `Spectre.xcodeproj`，執行 `Spectre` scheme：

   ```bash
   xcodegen generate
   ```

   也可以在命令列建置 Mac App：

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

4. 想長期使用 Mac App 的話，將它複製到「應用程式」檔案夾：

   ```bash
   ditto build/DerivedData/Build/Products/Release/Spectre.app /Applications/Spectre.app
   ```

要在 iPhone 或 iPad 上執行，請在 Xcode 中為 target 選擇你的開發團隊。

## 使用方式

Spectre 開啟後是登入畫面。填寫伺服器（`host` 或 `host:port`，連接埠預設 4442）、使用者名稱和密碼，再選擇一個桌面。第一次連線時會請你確認伺服器的憑證指紋。伺服器若還需要其他資訊（例如一次性驗證碼），會另外詢問；密碼留空的話，所有提問都會這樣逐一詢問。

### 鍵盤和滑鼠

Cmd 以 Super 鍵（Windows 鍵）傳送，因此在遠端桌面上拷貝貼上仍是 Ctrl+C 和 Ctrl+V。只有下列快速鍵留在本機：

| 快速鍵 | 作用 |
|---|---|
| Ctrl+Cmd+G | 擷取或釋放滑鼠（也可使用工具列的「擷取滑鼠」按鈕） |
| Ctrl+Cmd+F | 全螢幕 |
| Cmd+Q | 結束 |

### iPad 和 iPhone 上的觸控

以工具列切換兩種模式：

- **觸控**：指標跟著手指移動。點一下是按一下，長按是右鍵，單指拖移是拖曳，雙指拖移是捲動，雙指或三指點一下是右鍵或中鍵。
- **觸控式軌跡板**：螢幕當作觸控式軌跡板使用。單指移動游標，點一下即按一下。

### 聲音和麥克風

主機傳送聲音時就會播放（wraith 能擷取到工作階段的音訊時會傳送）。工具列的 **靜音** 只在本機靜音，設定會被記住。

工具列的 **麥克風** 會將本機麥克風傳送到遠端桌面，成為工作階段的預設錄音裝置。每次工作階段開始時都是關閉的，第一次使用時系統會要求權限。目前尚無回音消除，請戴耳機，否則遠端桌面會聽到它自己的聲音。

## 開發

### 測試

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

兩個套件都內建行程內的測試主機和測試 lobby，端對端測試走的是本機迴路上真實的 QUIC 連線。SpectreKit 的測試還會解碼 H.264 和 HEVC 彩條並以 Metal 算繪。在 iPad 模擬器上執行：

```bash
(cd Packages/GDPKit && xcodebuild test -scheme GDPKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-GDPKit)
```

```bash
(cd Packages/SpectreKit && xcodebuild test -scheme SpectreKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-SpectreKit)
```

### 不連伺服器執行

加上下列任一參數啟動時，Spectre 會略過登入直接播放。它先以 VideoToolbox 編碼一段 10 秒的 1080p60 測試串流（約 3 秒），然後循環播放。左上角顯示解碼、顯示和工作階段的統計，每秒更新一次，同時輸出到 stdout；工具列可切換來源、編碼和顯示節奏。來源有三種：

- **Loopback**（預設）：App 內的測試主機透過真實的 GDP 工作階段（127.0.0.1 上的 QUIC）傳送測試串流。它每秒還會嗶一聲，用來測試聲音。
- **Direct**：測試串流直接送進解碼器，不經過網路。
- **Remote**：以靜態 token 啟動的 wraith（規格 §6.11）：

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --connect HOST:PORT --token TOKEN --fingerprint SHA256
```

效能測試模式：暖機 2 秒後量測 N 秒，輸出統計後結束。

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

其他參數：`--source loopback|direct`、`--codec h264|h265`、`--mode onArrival|displayLink`、`--in-flight <N，0 表示不限>`、`--screen <螢幕編號>`、`--rate <display link Hz>`、`--min-present-ms <ms>`、`--host-clipboard <文字>`（loopback 主機剪貼簿的初始內容）。

### iOS 和 iPadOS 模擬器

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

iOS 上 App 從 UIKit 的 app delegate 啟動，這樣根視圖控制器才能鎖定指標（見 [docs/input.md](docs/input.md)）。如果安裝過這項改動之前的版本，請先解除安裝一次（`xcrun simctl uninstall booted org.ghost.spectre.apple`），否則系統會還原舊視窗，畫面會一直是黑的。

模擬器中 VideoToolbox 是軟體解碼，也沒有 `presentedTime`，因此在模擬器中量到的耗時無法和實機或 Mac 比較。

### 目錄結構

| 路徑 | 內容 |
|---|---|
| `project.yml` | XcodeGen 專案：一個同時支援 macOS 和 iOS 的 App target |
| `App/` | App 本身：各平台進入點、登入和工作階段介面、圖示 |
| `Packages/GDPKit/` | 通往 libgdp 的 C 橋接（`Native/`）及其 Swift 封裝：工作階段、lobby、測試主機 |
| `Packages/SpectreKit/` | 共用程式碼：工作階段、VideoToolbox 解碼、Metal 顯示、輸入、登入流程 |
| `scripts/` | 建置相依套件和 xcframework 的腳本 |
| `docs/` | 設計文件和量測紀錄（簡體中文） |
| `experiments/` | 一次性的實驗（例如 Swift/C++ 互通性的驗證），不屬於 App |
| `third_party/ghost/` | 上游 ghost（git 子模組，唯讀） |

### 設計文件

[`docs/`](docs/) 下的文件記錄了各部分如何運作、量測了什麼、過程中遇過哪些問題。這些文件以簡體中文撰寫。

- [prototype-findings.md](docs/prototype-findings.md)：原型階段的三個技術風險及其結論（從 Swift 呼叫 libgdp、零拷貝顯示、為 iOS 交叉編譯）
- [session-client.md](docs/session-client.md)：工作階段層，對照規格 §6–§11 逐條檢查
- [login.md](docs/login.md)：lobby 登入和憑證信任
- [saved-logins.md](docs/saved-logins.md)：鑰匙圈中儲存的密碼，一鍵登入
- [reconnect.md](docs/reconnect.md)：斷線重連、重播登入、iOS 背景執行
- [keep-alive.md](docs/keep-alive.md)：QUIC 保活，以及斷線要多久才會發現
- [input.md](docs/input.md)：鍵盤、滑鼠、游標和觸控
- [keyboard.md](docs/keyboard.md)：iOS 螢幕鍵盤、字元到按鍵的轉換、按鍵列
- [audio.md](docs/audio.md)：聲音、抖動緩衝、Opus 解碼、麥克風
- [clipboard.md](docs/clipboard.md)：Mac 和 iPad 上的剪貼簿、回聲抑制、貼上提示
- [gamepad.md](docs/gamepad.md)：遊戲控制器、按鍵對應、Home 鍵
- [localization.md](docs/localization.md)：介面語言、術語表、如何新增一條字串
- [app-icon.md](docs/app-icon.md)：App 圖示的設計和修改方式

## 參與貢獻

歡迎提交 issue 和 pull request；較大的改動請先開 issue 討論。有幾點需要了解：

- 用戶端程式碼依照 GDP 規格（`third_party/ghost/docs/spec/gdp-spec.md`）和公開標準撰寫。上游 ghost 大部分的程式碼採用 GPL-3.0，請不要複製或移植其中的程式碼，包括上游自己的 spectre 用戶端；只有 `libgdp/` 和協定規格採用 MIT。
- 提交改動前請跑過兩個套件的測試；行為有變化時，同步更新 `docs/` 下對應的文件。
- 新的介面文字需要在 String Catalog 中補齊所有語言的翻譯，見 [docs/localization.md](docs/localization.md)。

## 致謝

spectre-apple 的靈感來自 [Joseph Saiko](https://saiko.dev) 的 [ghost](https://github.com/jsaiko/ghost)。ghost 是一套完整的遠端桌面系統，包含 GDP 協定、主機端 wraith 和 Linux 用戶端 spectre。本專案使用 ghost 的協定函式庫 libgdp，依照 ghost 公開的協定規格和設計文件撰寫，名稱也沿用上游用戶端的 Spectre。感謝原作者將 ghost 開源，並以 MIT 授權開放 libgdp 和協定規格，這個專案才得以實現。

spectre-apple 是獨立的第三方用戶端，並非 ghost 官方專案。

## 授權

[MIT](LICENSE)。

- 上游 ghost 中，`libgdp/` 和協定規格採用 MIT 授權，其餘部分（包括上游自己的 spectre 用戶端）採用 GPL-3.0-only。本專案只編譯 `libgdp/`，用戶端程式碼依照規格和公開標準自行撰寫，沒有複製或移植 GPL 部分的程式碼。
- 編譯出的 App 靜態連結了 ngtcp2、OpenSSL、Protocol Buffers、Abseil、zstd，它們都採用寬鬆授權（MIT、Apache-2.0、BSD-3-Clause）。散布二進位檔時需附上它們的授權聲明，見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
