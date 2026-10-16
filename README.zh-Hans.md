<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="Spectre 图标">

# spectre-apple

**Spectre**：[ghost](https://github.com/jsaiko/ghost) 远程桌面在 Mac、iPad 和 iPhone 上的原生客户端

[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iPadOS%20%7C%20iOS%2027-lightgrey)](#运行要求)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) | **简体中文** | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [Español](README.es.md)

</div>

![Mac 上的 Spectre，连接着 Ubuntu 主机上的 GNOME 桌面](docs/images/macos-session.webp)

ghost 是一套开源的远程桌面系统：主机端（wraith）通过 GDP 协议把 Linux 桌面传输出去，客户端负责显示画面并把输入发回去。spectre-apple 把这个客户端带到了 Apple 设备上：一个用 Swift、SwiftUI、Metal 和 VideoToolbox 写成的原生 App，底层使用 ghost 自己的协议库 libgdp。

spectre-apple 是受 ghost 启发的独立第三方客户端，并非 ghost 官方项目。详见[致谢](#致谢)。

## 功能

**登录**

- 用用户名和密码登录 ghost 服务器；服务器后续的提问（比如一次性验证码）会依次询问。然后选择设备和桌面会话，或者接管一个正在运行的会话。
- 首次信任（TOFU）：第一次连接时确认服务器的证书指纹，之后会记住。登录页的 **信任的服务器…** 列出记住的指纹，也可以删除。
- 勾选 **记住**，登录信息会保存在钥匙串里，只留在本机；之后点一下最近登录就能连接。
- 连接断开时（切换 Wi-Fi、Mac 睡眠、iOS 挂起 App）会自动重连。

**画面与声音**

- H.264 和 HEVC 由 VideoToolbox 硬件解码，交给 Metal 显示，全程不复制帧；丢帧和延迟统计会回报给主机。
- 远程桌面的大小跟随窗口（iPad 和 iPhone 上是屏幕）。工具栏的**分辨率**菜单可以关掉这个功能，或者改为按 Retina 的完整分辨率请求。
- 远程桌面的声音，带能掩盖丢包的抖动缓冲，可以静音。
- 打开麦克风后，把本机麦克风发送到远程桌面。

**输入**

- 按键按物理位置发送，所以打出什么字符由远端的键盘布局决定。
- 鼠标支持所有按键和平滑滚动，还有一个发送相对位移的捕获模式，适合游戏和 3D 视图。远端光标在本地绘制。
- iPad 上：支持硬件键盘、触控板和鼠标；手指可以用"直接触摸"或"触控板"两种模式。
- iPhone 和 iPad 上：用屏幕键盘在远程桌面上打字，键盘上方是同一套按键栏。

**iPad 和 iPhone 上**

- 远程画面铺满整个屏幕，控件以 Liquid Glass 浮在上面，平时收成底部两角的圆钮：左边是会话工具栏（更多、粘贴到主机、键盘），右边是按键栏：方向键，Esc、Ctrl+C、Tab、退格、回车，按下后保持到下一个键的 Ctrl、Alt、Super、Shift，以及 Super+Tab 这类 iPadOS 自己截走的组合键。
- 提示词面板：用 iPad 的输入法、听写或粘贴写好一段文字，一次性送到主机的光标处，经主机剪贴板加 Ctrl+Shift+V（也可以选 Ctrl+V 或逐字键入）。
- 双指捏合缩放画面，或者**填满屏幕**；放大后指针靠近边缘时画面跟着移动。
- 首页列出你的主机和各自上次的画面；iPad 菜单栏有**会话**菜单，没有任何会抢走远程桌面按键的快捷键。

**共享**

- 双向同步文本剪贴板，默认关闭，需要时再打开。
- 最多四个游戏手柄，以标准手柄的形式转发。

**其他**

- 断开连接（远端会话继续运行）或注销（结束远端会话）。
- 界面支持英语、简体中文、繁体中文、日语和西班牙语，跟随系统语言。

### 路线图

尚未完成：

- 无损增强层（refine），以及 AV1 和 PyroWave 编码
- 麦克风的回声消除
- iOS 上校验证书颁发机构签发的证书（目前和其他证书一样按首次信任处理）

## 截图

| 在 Mac 上登录 | iPad 的触控板模式 |
|---|---|
| ![Mac 上的登录页](docs/images/macos-login.webp) | ![iPad 上触控板模式的会话，远端光标由 Metal 绘制](docs/images/ipad-trackpad-mode.jpg) |

## 运行要求

- 搭载 Apple 芯片、运行 macOS 27 的 Mac，或者运行 iOS / iPadOS 27 的 iPhone、iPad（只支持 arm64）
- 一台可以连接的 ghost 主机（ghostd 和 wraith），搭建方法见 [ghost](https://github.com/jsaiko/ghost) 项目

## 快速开始

Mac 版可以在 [GitHub Releases](https://github.com/pokoblin/spectre-apple/releases/latest) 下载：下载 `.dmg`，打开后把 Spectre 拖到“应用程序”文件夹即可。App 使用 Developer ID 签名，并经过 Apple 公证。

iPhone 和 iPad 版，或者想参与开发，请按下面的步骤从源码构建。

### 工具

- Xcode 27，以及 iOS 27 模拟器运行时
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `cmake`（3.25 或更高）和 `ninja`：`brew install cmake ninja`
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

如果 vcpkg 不在 `~/src/vcpkg`，请设置 `VCPKG_ROOT`。

### 构建

1. 克隆仓库，连同上游 ghost 子模块一起（已有的克隆里运行 `git submodule update --init`）：

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

2. 构建 `GDPCore.xcframework`，里面是 libgdp、它的依赖和一层很薄的 C 桥接。产物写到 `Packages/GDPKit/Artifacts/`，不提交到仓库。第一次构建需要几分钟，之后会复用 vcpkg 的二进制缓存。日志在 `build/logs/`。

   ```bash
   scripts/build-gdpcore.sh
   ```

   默认构建 `macos`、`ios` 和 `ios-simulator` 三个 slice；只要其中几个时把名字写上，例如 `scripts/build-gdpcore.sh macos`。

3. 生成 Xcode 工程，然后打开 `Spectre.xcodeproj`，运行 `Spectre` scheme：

   ```bash
   xcodegen generate
   ```

   也可以在命令行构建 Mac App：

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

4. 想长期使用 Mac App 的话，把它复制到"应用程序"文件夹：

   ```bash
   ditto build/DerivedData/Build/Products/Release/Spectre.app /Applications/Spectre.app
   ```

要在 iPhone 或 iPad 上运行，请在 Xcode 里为 target 选择你的开发团队。

## 使用

Spectre 打开后是登录页。填写服务器（`host` 或 `host:port`，端口默认 4442）、用户名和密码，再选择一个桌面。第一次连接时会请你确认服务器的证书指纹。服务器如果还要别的信息（比如一次性验证码），会单独询问；密码留空的话，所有提问都会这样逐个询问。

### 键盘和鼠标

Cmd 作为 Super 键（Windows 键）发送，所以在远程桌面上复制粘贴仍然是 Ctrl+C 和 Ctrl+V。只有下面几个快捷键留在本机：

| 快捷键 | 作用 |
|---|---|
| Ctrl+Cmd+G | 捕获或释放鼠标（也可以用工具栏的"捕获鼠标"按钮） |
| Ctrl+Cmd+F | 全屏 |
| Cmd+Q | 退出 |

### iPad 和 iPhone 上的触摸

用工具栏切换两种模式：

- **触摸**：指针跟着手指走。轻点是单击，长按是右键，单指拖动是拖拽，双指拖动是滚动，双指或三指轻点是右键或中键。
- **触控板**（默认）：屏幕当作触控板用。单指移动光标，轻点单击。

### 声音和麦克风

主机发送声音时就会播放（wraith 能采集到会话的音频时会发送）。工具栏的 **静音** 只在本机静音，设置会被记住。

工具栏的 **麦克风** 把本机麦克风发送到远程桌面，在那里成为会话的默认录音设备。每次会话开始时都是关闭的，第一次使用时系统会请求权限。目前还没有回声消除，请戴耳机，否则远程桌面会听到它自己的声音。

## 开发

### 测试

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

两个包都自带进程内的测试主机和测试 lobby，端到端测试走的是本机回环上真实的 QUIC 连接。SpectreKit 的测试还会解码 H.264 和 HEVC 彩条并用 Metal 渲染。在 iPad 模拟器上运行：

```bash
(cd Packages/GDPKit && xcodebuild test -scheme GDPKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-GDPKit)
```

```bash
(cd Packages/SpectreKit && xcodebuild test -scheme SpectreKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-SpectreKit)
```

### 不连服务器运行

带上下面任意一个参数启动时，Spectre 会跳过登录直接播放。它先用 VideoToolbox 编码一段 10 秒的 1080p60 测试流（约 3 秒），然后循环播放。左上角显示解码、显示和会话的统计，每秒刷新一次，同时打印到 stdout；工具栏可以切换来源、编码和显示节奏。来源有三种：

- **Loopback**（默认）：App 内的测试主机通过真实的 GDP 会话（127.0.0.1 上的 QUIC）发送测试流。它每秒还会响一声，用来测试声音。
- **Direct**：测试流直接送进解码器，不经过网络。
- **Remote**：用静态 token 启动的 wraith（规范 §6.11）：

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --connect HOST:PORT --token TOKEN --fingerprint SHA256
```

基准测试模式：预热 2 秒后测量 N 秒，打印统计后退出。

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

其他参数：`--source loopback|direct`、`--codec h264|h265`、`--mode onArrival|displayLink`、`--in-flight <N，0 表示不限>`、`--screen <屏幕序号>`、`--rate <display link Hz>`、`--min-present-ms <ms>`、`--host-clipboard <文本>`（loopback 主机剪贴板的初始内容）。

### iOS 和 iPadOS 模拟器

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

iOS 上 App 从 UIKit 的 app delegate 启动，这样根视图控制器才能锁定指针（见 [docs/input.md](docs/input.md)）。如果装过这次改动之前的版本，先卸载一次（`xcrun simctl uninstall booted org.ghost.spectre.apple`），否则系统会恢复旧窗口，画面一直是黑的。

模拟器里 VideoToolbox 是软件解码，也没有 `presentedTime`，所以在模拟器里测到的耗时不能和真机或 Mac 比较。

### 目录结构

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程：一个同时支持 macOS 和 iOS 的 App target |
| `App/` | App 本身：各平台入口、登录和会话界面、图标 |
| `Packages/GDPKit/` | 通往 libgdp 的 C 桥接（`Native/`）及其 Swift 封装：会话、lobby、测试主机 |
| `Packages/SpectreKit/` | 共享代码：会话、VideoToolbox 解码、Metal 显示、输入、登录流程 |
| `scripts/` | 构建依赖和 xcframework 的脚本 |
| `docs/` | 设计文档和测量记录（简体中文） |
| `experiments/` | 一次性的实验（比如 Swift/C++ 互操作的验证），不属于 App |
| `third_party/ghost/` | 上游 ghost（git 子模块，只读） |

### 设计文档

[`docs/`](docs/) 下的文档记录了各部分怎么工作、测量了什么、过程中踩过哪些坑。

- [prototype-findings.md](docs/prototype-findings.md)：原型阶段的三个技术风险及其结论（从 Swift 调用 libgdp、零拷贝显示、为 iOS 交叉编译）
- [session-client.md](docs/session-client.md)：会话层，对照规范 §6–§11 逐条检查
- [login.md](docs/login.md)：lobby 登录和证书信任
- [saved-logins.md](docs/saved-logins.md)：钥匙串里保存的密码，一键登录
- [reconnect.md](docs/reconnect.md)：断线重连、重放登录、iOS 后台
- [keep-alive.md](docs/keep-alive.md)：QUIC 保活，以及断线要多久才能发现
- [resolution.md](docs/resolution.md)：远程桌面的分辨率跟随窗口
- [input.md](docs/input.md)：键盘、鼠标、光标和触摸
- [keyboard.md](docs/keyboard.md)：iOS 屏幕键盘、字符到按键的转换、按键栏
- [audio.md](docs/audio.md)：声音、抖动缓冲、Opus 解码、麦克风
- [clipboard.md](docs/clipboard.md)：Mac 和 iPad 上的剪贴板、回声抑制、粘贴提示
- [gamepad.md](docs/gamepad.md)：游戏手柄、按键映射、Home 键
- [localization.md](docs/localization.md)：界面语言、术语表、如何新增一条字符串
- [app-icon.md](docs/app-icon.md)：App 图标的设计和修改方法

## 参与贡献

欢迎提交 issue 和 pull request；较大的改动请先开 issue 讨论。有几点需要了解：

- 客户端代码是按 GDP 规范（`third_party/ghost/docs/spec/gdp-spec.md`）和公开标准编写的。上游 ghost 的大部分代码是 GPL-3.0，请不要复制或移植其中的代码，包括上游自己的 spectre 客户端；只有 `libgdp/` 和协议规范是 MIT。
- 提交改动前请跑通两个包的测试；行为有变化时，同步更新 `docs/` 下对应的文档。
- 新的界面文字需要在 String Catalog 里补齐所有语言的翻译，见 [docs/localization.md](docs/localization.md)。

## 致谢

spectre-apple 的灵感来自 [Joseph Saiko](https://saiko.dev) 的 [ghost](https://github.com/jsaiko/ghost)。ghost 是一个完整的远程桌面系统，包括 GDP 协议、主机端 wraith 和 Linux 客户端 spectre。本项目使用 ghost 的协议库 libgdp，按 ghost 公开的协议规范和设计文档编写，名字也沿用了上游客户端的 Spectre。感谢原作者把 ghost 开源，并以 MIT 许可证开放 libgdp 和协议规范，这个项目才得以实现。

spectre-apple 是独立的第三方客户端，并非 ghost 官方项目。

## 许可证

[MIT](LICENSE)。

- 上游 ghost 中，`libgdp/` 和协议规范是 MIT，其余部分（包括上游自己的 spectre 客户端）是 GPL-3.0-only。本项目只编译 `libgdp/`，客户端代码照规范和公开标准自行编写，没有复制或移植 GPL 部分的代码。
- 编译出的 App 静态链接了 ngtcp2、OpenSSL、Protocol Buffers、Abseil、zstd，它们都是宽松许可证（MIT、Apache-2.0、BSD-3-Clause）。分发二进制时要附上它们的许可声明，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
