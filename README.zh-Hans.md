<div align="center">

<img src="assets/app-icon.png" width="128" alt="Spectre 图标">

# spectre-apple

**Spectre**：[ghost](https://github.com/jsaiko/ghost) 远程桌面在 Mac、iPad 和 iPhone 上的原生客户端

[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iPadOS%20%7C%20iOS%2027-lightgrey)](#运行要求)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) | **简体中文** | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [Español](README.es.md)

</div>

![Mac 上的 Spectre，连接着 Ubuntu 主机上的 GNOME 桌面](assets/macos-session.webp)

ghost 是一套开源的远程桌面系统：主机端（wraith）通过 GDP 协议把 Linux 桌面传输出去，客户端负责显示画面并把输入发回去。spectre-apple 就是这个客户端的 Apple 设备版，用 Swift 写成，基于 SwiftUI、Metal 和 VideoToolbox，底层使用 ghost 的协议库 libgdp。

它是独立的第三方客户端，并非 ghost 官方项目（详见[致谢](#致谢)）。

## 功能

**连接**

- 用用户名和密码登录，服务器后续的提问（比如一次性验证码）也会依次回答；然后选择设备和桌面会话，或者接管一个正在运行的会话。
- 首次信任（TOFU）：第一次确认服务器的证书指纹，之后会记住；**信任的服务器…** 可以列出并删除它们。
- 密码可以和服务器一起保存，一键连接，也可以选择存进钥匙串。
- 连接断开时（切换 Wi-Fi、睡眠、iOS 挂起 App）会自动重连。

**画面与声音**

- H.264 和 HEVC 硬件解码，交给 Metal 显示，全程不复制帧。
- 远程桌面的大小跟随窗口或屏幕，也可以按 Retina 的完整分辨率运行。
- Mac 上全屏时隐藏工具栏和菜单栏，指针移到顶部边缘时才出现。
- 远程桌面的声音，带抖动缓冲和静音按钮。

**输入**

- 按键按物理位置发送，所以打出什么字符由远端的键盘布局决定。
- 鼠标支持所有按键和平滑滚动，还有一个发送相对位移的捕获模式，适合游戏和 3D；远端光标在本地绘制。
- iPad 上：支持硬件键盘、触控板和鼠标，手指可以用直接触摸或触控板两种模式。
- iPhone 和 iPad 上：屏幕键盘，配有按键栏，提供方向键、Esc、Tab、按下后保持的修饰键，以及 Super+Tab 这类系统组合键。

**Mac 上**

- 主机列表首页是一个窗口，每台主机显示上次的画面；每个会话各开一个窗口，可以同时连几台。
- 工具栏放着剪贴板、捕获鼠标和静音，副标题显示往返延迟和帧率。
- **Session** 菜单：捕获鼠标、剪贴板，以及被 macOS 自己截走的组合键。没有新增快捷键，所有按键都能发给远程桌面。

**iPad 和 iPhone 上**

- 远程画面铺满整个屏幕，控件以 Liquid Glass 浮在上面，可以收成两角的两个圆钮。
- 提示词面板：用系统输入法、听写或粘贴写好一段文字，一次性送到主机的光标处。
- 语音输入：按住麦克风键说话，说的话在本机转成文字，在主机上打出来。
- 双指捏合缩放画面，或者用**填满屏幕**；放大后画面跟着指针移动。
- 区域提醒：盯住屏幕上的一块区域（比如终端），它停止变化或开始变化时提醒你。

**其他**

- 双向同步文本剪贴板（默认关闭，需要时再打开），最多支持四个游戏手柄。
- 断开连接（会话继续运行）或注销（结束会话）。
- 英语、简体中文、繁体中文、日语和西班牙语。

**尚未完成：** 无损增强层、AV1 和 PyroWave，把本机麦克风发送到主机（已经写好，暂时停用），以及 iOS 上校验证书颁发机构签发的证书。

## 截图

| Mac 上的首页窗口 | iPad 上的会话 |
|---|---|
| ![Mac 上的首页窗口：侧栏是主机，右边是所选主机的上次画面和连接按钮](assets/macos-home.webp) | ![iPad 上的 GNOME 桌面，大小跟随 iPad 屏幕，右下角的按键栏已展开](assets/ipad-session.webp) |

## 运行要求

- 搭载 Apple 芯片、运行 macOS 27 的 Mac，或者运行 iOS / iPadOS 27 的 iPhone、iPad
- 一台 ghost 主机（ghostd 和 wraith），搭建方法见 [ghost](https://github.com/jsaiko/ghost) 项目

## 安装

Mac 版可以在 [GitHub Releases](https://github.com/pokoblin/spectre-apple/releases/latest) 下载经过公证的 `.dmg`，把 Spectre 拖到“应用程序”文件夹即可。iPhone 和 iPad 版请从源码构建。

## 使用

用 **+** 添加服务器：地址（`host` 或 `host:port`，端口默认 4442）、你的用户名，还可以填密码。然后点 **连接**，选择一个桌面。第一次连接时请确认服务器的证书指纹。

Mac 上每个会话各开一个窗口；关掉它就断开连接，主机上的桌面会话继续运行。iPad 和 iPhone 上会话盖在首页上面。

**Mac 上的键盘。** Cmd 作为 Super 键发送，所以在远程桌面上复制粘贴仍然是 Ctrl+C 和 Ctrl+V。只有下面几个快捷键留在本机：

| 快捷键 | 作用 |
|---|---|
| Ctrl+Cmd+G | 捕获或释放鼠标 |
| Ctrl+Cmd+F | 全屏 |
| Cmd+Q | 退出 |

**iPad 和 iPhone 上的触摸。** 用 **更多 › 输入方式** 切换两种模式：

- **触控板**（默认）：单指移动光标，轻点单击。
- **触摸**：指针跟着手指走。轻点是单击，长按是右键，单指拖动是拖拽，双指拖动是滚动，双指或三指轻点是右键或中键。

## 从源码构建

需要 Xcode 27 和 iOS 27 模拟器运行时、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、`cmake` 3.25 或更高和 `ninja`（`brew install cmake ninja`），以及 [vcpkg](https://github.com/microsoft/vcpkg)，最好固定在上游 CI 使用的提交：

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

如果 vcpkg 在别的位置，请设置 `VCPKG_ROOT`。

1. 克隆仓库，连同 ghost 子模块一起。子模块目前指向 [pokoblin/ghost](https://github.com/pokoblin/ghost) fork（上游加文件传输）。已有的克隆里运行 `git submodule sync && git submodule update --init`。

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

2. 构建 `GDPCore.xcframework`（libgdp、它的依赖和一层 C 桥接），产物写到 `Packages/GDPKit/Artifacts/`。第一次构建需要几分钟；只想构建其中几个 slice 时，传入 `macos`、`ios` 或 `ios-simulator`。

   ```bash
   scripts/build-gdpcore.sh
   ```

3. 生成 Xcode 工程，然后打开 `Spectre.xcodeproj`，运行 `Spectre` scheme：

   ```bash
   xcodegen generate
   ```

   也可以在命令行构建 Mac App，再复制到“应用程序”文件夹：

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

   ```bash
   ditto build/DerivedData/Build/Products/Release/Spectre.app /Applications/Spectre.app
   ```

要在 iPhone 或 iPad 上运行，请在 Xcode 里为 target 选择你的开发团队。

## 开发

### 测试

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

两个包都自带进程内的测试主机和测试 lobby，端到端测试走的是本机回环上真实的 QUIC 连接。要在 iPad 模拟器上运行，在每个包里用 `-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0'` 运行 `xcodebuild test`。

### 不连服务器运行

下面这些参数会跳过登录，播放一段生成的 1080p60 测试流，统计信息显示在画面上，同时打印到 stdout：

- `--source loopback`（默认）：App 内的测试主机，通过 127.0.0.1 上真实的 GDP 会话发送
- `--source direct`：直接送进解码器，不经过网络
- `--connect HOST:PORT --token TOKEN --fingerprint SHA256`：用静态 token 启动的 wraith
- `--bench N`：测量 N 秒，打印结果后退出

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

其他参数：`--codec h264|h265`、`--mode onArrival|displayLink`、`--in-flight N`、`--screen N`、`--rate HZ`、`--min-present-ms MS`、`--host-clipboard TEXT`。

在 iOS 模拟器里：

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

模拟器里是软件解码，所以测到的耗时不能和真机比较。

### 目录结构

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程：一个多平台 App target |
| `App/` | App 本身：入口、首页、会话界面、iPad 和 iPhone 的控件、图标 |
| `Packages/GDPKit/` | 通往 libgdp 的 C 桥接及其 Swift 封装 |
| `Packages/SpectreKit/` | 会话、解码、Metal 显示、输入、登录 |
| `scripts/` | 构建依赖和 xcframework 的脚本 |
| `third_party/ghost/` | ghost 子模块（pokoblin/ghost fork），只编译其中的 libgdp |

## 参与贡献

欢迎提交 issue 和 pull request；较大的改动请先开 issue 讨论。

- 客户端代码按 GDP 规范（`third_party/ghost/docs/spec/gdp-spec.md`）和公开标准编写。上游 ghost 的大部分代码是 GPL-3.0，请不要复制或移植其中的代码，包括上游自己的 spectre 客户端；只有 `libgdp/` 和协议规范是 MIT。
- 提交改动前请跑通两个包的测试。
- 新的界面文字需要补齐所有语言的翻译；`scripts/sync-strings.sh` 会更新 String Catalog。

## 致谢

spectre-apple 的灵感来自 [Joseph Saiko](https://saiko.dev) 的 [ghost](https://github.com/jsaiko/ghost)：GDP 协议、主机端 wraith 和 Linux 客户端 spectre。本项目使用 ghost 的 libgdp，按 ghost 公开的协议规范和设计文档编写，名字也沿用了上游客户端的 Spectre。感谢原作者把 ghost 开源，并以 MIT 许可证开放 libgdp 和协议规范，没有它们就没有这个项目。

## 许可证

[MIT](LICENSE)。

- 上游 ghost 中，`libgdp/` 和协议规范是 MIT，其余部分是 GPL-3.0-only。本项目只编译 `libgdp/`，没有复制或移植 GPL 部分的任何代码。
- App 静态链接了 ngtcp2、OpenSSL、Protocol Buffers、Abseil 和 zstd（MIT、Apache-2.0、BSD-3-Clause），它们的许可声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
