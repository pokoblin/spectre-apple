# spectre-apple

[English](README.md) | **简体中文** | [繁體中文](README.zh-Hant.md) | [Español](README.es.md)

[ghost](https://github.com/jsaiko/ghost) 远程桌面的 Apple 原生客户端，支持 macOS、iPadOS 和 iOS（只支持 Apple 芯片 / arm64）。App 显示名 **Spectre**，Bundle ID `org.ghost.spectre.apple`。

> **致谢**：本项目的灵感来自 [Joseph Saiko](https://saiko.dev) 的 [ghost](https://github.com/jsaiko/ghost)。ghost 是一个完整的远程桌面系统，包括 GDP 协议、host 端 wraith 和 Linux 客户端 spectre。spectre-apple 让 Apple 设备也能连上 ghost：它使用 ghost 的协议库 libgdp，按 ghost 公开的协议规范和设计文档编写，名字也沿用了上游客户端的 Spectre。感谢原作者把 ghost 开源，并以 MIT 许可证开放 libgdp 和协议规范，这个项目才得以实现。本项目是独立的第三方客户端，并非 ghost 官方项目。

![iPad 上的会话：触控板模式，Metal 绘制的远端光标](docs/images/ipad-trackpad-mode.jpg)

- **协议层**：上游的 C++ libgdp（QUIC：ngtcp2 + OpenSSL；protobuf；zstd），编译成静态库打包为 xcframework，通过一层 C ABI 暴露给 Swift。
- **平台层**：Swift 6、SwiftUI、Metal、VideoToolbox。会话、登录和输入的客户端逻辑都照 GDP 规范（`third_party/ghost/docs/spec/gdp-spec.md`）自行实现。

## 现状

已经可用：

- **登录**：lobby 登录（§4、§5），首次连接时确认并记住服务器证书（TOFU），按服务器的提示交互式认证，选择设备和桌面会话，接管已有会话。见 [docs/login.md](docs/login.md)。
- **视频**：H.264 / HEVC，VideoToolbox 硬件解码，零拷贝交给 Metal 显示；向 host 回报丢帧和延迟统计（StatsReport）。见 [docs/session-client.md](docs/session-client.md)、[docs/prototype-findings.md](docs/prototype-findings.md)。
- **输入**：键盘按物理位置转发；鼠标支持绝对坐标、各按键和平滑滚动，可以捕获鼠标发送相对移动；显示远端光标；iPad 支持硬件键盘、触控板和鼠标，手指可以选“直接触摸”或“触控板”两种用法。见 [docs/input.md](docs/input.md)。
- **音频**：播放远端桌面的声音（Opus，用系统自带的解码器），60 ms 的抖动缓冲，丢包时做补偿；工具栏可以静音。打开麦克风后会把它发给远端桌面。见 [docs/audio.md](docs/audio.md)。
- **剪贴板**：文本双向同步（§7.9），默认关闭，在工具栏里打开。Mac 上在 Spectre 处于活跃状态时发送复制的内容；iPad 上用粘贴按钮发送，不会弹出系统的粘贴提示，也可以选择自动发送。见 [docs/clipboard.md](docs/clipboard.md)。
- **会话控制**：断开（远端会话保留）、登出（结束远端会话）。

还没有做：手柄、无损细化层（refine）、屏幕软键盘、AV1 / PyroWave。

## 构建

### 需要的工具

- Xcode 27（含 iOS 27 模拟器运行时）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `cmake`（3.25+）和 `ninja`：`brew install cmake ninja`
- [vcpkg](https://github.com/microsoft/vcpkg)，建议固定在上游 CI 用的提交：

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

vcpkg 不在 `~/src/vcpkg` 的话，后面的命令前设置 `VCPKG_ROOT`。

### 步骤

1. 取代码（包括上游 ghost 的 submodule）：

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

   已经克隆过的话补上 submodule：`git submodule update --init`。

2. 编译 `GDPCore.xcframework`：libgdp 和它的依赖（vcpkg 静态库）加上 C 桥接层，合并成 `Packages/GDPKit/Artifacts/GDPCore.xcframework`（不进 git）。首次编译依赖要几分钟，之后有 vcpkg 的二进制缓存。日志在 `build/logs/`。

   ```bash
   scripts/build-gdpcore.sh
   ```

   默认编 `macos`、`ios`、`ios-simulator` 三个平台，也可以只编其中几个，例如 `scripts/build-gdpcore.sh macos`。

3. 生成 Xcode 工程，打开 `Spectre.xcodeproj`，选 `Spectre` scheme 运行：

   ```bash
   xcodegen generate
   ```

   也可以在命令行编译 macOS 版：

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

在真机上运行，需要在 Xcode 里给 target 选一个开发者 Team。

## 使用

App 启动后是登录页：输入服务器（`host[:port]`，默认端口 4442）和用户名，按服务器的提示登录，选择桌面后进入会话。首次连接会先请你确认服务器的证书指纹。

**没有服务器？**点 **Try the demo host**（用户 demo，密码 demo）：App 内会起一个测试 lobby 和测试 host，走完整的登录和会话流程，画面是测试码流，统计浮层会显示 host 收到的输入。

**键盘和鼠标**：按键按物理位置转发，由远端的键盘布局决定输入什么字符；Cmd 作为 Super（Windows 键）转发，所以远端的复制、粘贴仍然是 Ctrl+C、Ctrl+V。只有下面三个快捷键留在本地：

| 快捷键 | 作用 |
|---|---|
| Ctrl+Cmd+G | 捕获或释放鼠标（游戏、3D 视图用相对移动），工具栏上也有 Capture Mouse 按钮 |
| Ctrl+Cmd+F | 全屏 |
| Cmd+Q | 退出 |

**iPad 和 iPhone 上的手指**：用工具栏按钮在两种模式间切换。

- **Touch**：点在哪里，指针就在哪里。轻点是左键，长按是右键，单指拖动是左键拖动，双指拖动是滚动，双指或三指轻点是右键或中键。
- **Trackpad**：把屏幕当触控板用，单指移动光标，轻点是点击。

**声音**：host 发送声音时就会播放（wraith 能采集到会话的音频时就会发）。工具栏的 **Mute** 按钮只让本机静音，设置会被记住。demo 和 loopback 的测试 host 每秒响一下提示音。

**麦克风**：工具栏的 **Microphone** 按钮把本机麦克风发给远端桌面，远端会把它当作会话默认的录音设备。每个会话开始时都是关的；第一次打开时系统会请求权限。关掉就释放设备。还没有做回声消除，请戴耳机，否则远端会听到自己的声音。

## 开发

### 测试

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

两个包里都有一个进程内的测试 host（以及测试 lobby），通过真实的 QUIC 回环连接做端到端测试。SpectreKit 的测试还包括 H.264/HEVC 彩条的色彩校验和 Metal 渲染测试。在 iPad 模拟器上跑：

```bash
(cd Packages/GDPKit && xcodebuild test -scheme GDPKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-GDPKit)
```

```bash
(cd Packages/SpectreKit && xcodebuild test -scheme SpectreKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-SpectreKit)
```

### 跳过登录的开发模式

带下面任意命令行参数启动时，App 会跳过登录、直接播放。它先用 VideoToolbox 现编一段 10 秒的 1080p60 测试码流（约 3 秒），然后循环播放；左上角每秒更新一次解码、显示和会话的统计，stdout 也会打印同样的内容。工具栏可以切换来源、H.264/HEVC 和呈现节奏。来源有三种：

- **Loopback**（默认）：App 内的测试 host 通过真实的 GDP 会话（QUIC，127.0.0.1）发送测试码流。
- **Direct**：测试码流直接交给解码器，不经过网络。
- **Remote**：连接一个用静态 token 启动的 wraith（§6.11）：

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --connect HOST:PORT --token TOKEN --fingerprint SHA256
```

测量模式：预热 2 秒后测 N 秒，打印统计后退出。

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

其他参数：`--source loopback|direct`、`--codec h264|h265`、`--mode onArrival|displayLink`、`--in-flight <N，0 为不限>`、`--screen <屏幕序号>`、`--rate <display link Hz>`、`--min-present-ms <ms>`、`--host-clipboard <文本>`（loopback host 一开始的剪贴板内容）。

### iOS / iPadOS 模拟器

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

iOS 的入口是 UIKit 的 app delegate，这样根 view controller 才能锁定指针，见 [docs/input.md](docs/input.md)。如果之前装过旧版本（SwiftUI 入口），要先卸载一次（`xcrun simctl uninstall booted org.ghost.spectre.apple`），否则系统恢复旧窗口时会是一片黑屏。

在模拟器里 VideoToolbox 是软件解码，而且没有 `presentedTime`，所以模拟器上的耗时数字不能和真机或 macOS 比较。

### 目录

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程定义（一个 macOS + iOS 多平台 App target） |
| `App/` | 各平台入口和界面（登录、会话） |
| `Packages/GDPKit/` | libgdp 的 C 桥接（`Native/`）和 Swift 封装：会话、lobby、测试 host |
| `Packages/SpectreKit/` | 共用代码：会话、VideoToolbox 解码、Metal 显示、输入、登录流程 |
| `scripts/` | 编译依赖、生成 xcframework 的脚本 |
| `docs/` | 设计和实测记录 |
| `experiments/` | 一次性实验（如 Swift/C++ interop probe），不参与 App 构建 |
| `third_party/ghost/` | 上游 ghost（git submodule，只读） |

### 文档

- [docs/prototype-findings.md](docs/prototype-findings.md)：原型阶段的三个技术风险和验证结论（Swift 调用 libgdp、零拷贝显示、iOS 交叉编译）
- [docs/session-client.md](docs/session-client.md)：会话层，对照规范 §6–§11
- [docs/login.md](docs/login.md)：lobby 登录、证书信任、demo
- [docs/input.md](docs/input.md)：键盘、鼠标、光标、触摸
- [docs/audio.md](docs/audio.md)：音频、抖动缓冲、Opus 解码
- [docs/clipboard.md](docs/clipboard.md)：Mac 和 iPad 上的剪贴板、回声抑制、粘贴提示

## 许可证

[MIT](LICENSE)。

- 上游 ghost 中，`libgdp/` 和协议规范是 MIT，其余部分（包括上游自己的 spectre 客户端）是 GPL-3.0-only。本项目只编译 `libgdp/`，客户端代码照规范和公开标准自行编写，没有复制或移植 GPL 部分的代码。
- 编译出的 App 静态链接了 ngtcp2、OpenSSL、Protocol Buffers、Abseil、zstd，它们都是宽松许可证（MIT、Apache-2.0、BSD-3-Clause）。分发二进制时要附上它们的许可声明，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
