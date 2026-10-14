# spectre-apple

[ghost](https://github.com/jsaiko/ghost) 远程桌面的 Apple 原生客户端（macOS / iOS / iPadOS），显示名 **Spectre**，Bundle ID `org.ghost.spectre.apple`。

- 协议层：上游的 C++ libgdp（ngtcp2 + OpenSSL + protobuf + zstd），编译成静态库打包为 xcframework，通过一层 C ABI 暴露给 Swift。
- 平台层：Swift、SwiftUI、Metal、VideoToolbox。

原型的验证结论见 [docs/prototype-findings.md](docs/prototype-findings.md)；会话层（SessionClient）见 [docs/session-client.md](docs/session-client.md)；登录见 [docs/login.md](docs/login.md)；键盘、鼠标和触摸输入见 [docs/input.md](docs/input.md)。

## 目录

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程定义（一个 macOS + iOS 多平台 App target） |
| `App/` | 各平台入口和窗口 |
| `Packages/GDPKit/` | libgdp 的 xcframework + C 桥接 + Swift 封装 |
| `Packages/SpectreKit/` | 共用代码：会话、VideoToolbox 解码、Metal 显示 |
| `scripts/` | 编译依赖、生成 xcframework 的脚本 |
| `experiments/` | 一次性实验（如 Swift/C++ interop probe），不参与 App 构建 |
| `third_party/ghost/` | 上游 ghost（git submodule，只读） |

## 从零构建

### 需要的工具

- Xcode 27（含 iOS 27 模拟器运行时）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `cmake`（3.25+）、`ninja`：`brew install cmake ninja`
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

### 1. 取代码

```bash
git clone --recurse-submodules <this repo> spectre-apple
```

已经克隆过的话补上 submodule：

```bash
git submodule update --init
```

### 2. 编译 GDPCore.xcframework

libgdp 和依赖（vcpkg 静态库）加 C 桥接层，合并成 `Packages/GDPKit/Artifacts/GDPCore.xcframework`（不进 git）。首次编译依赖需要几分钟，之后有 vcpkg 二进制缓存。

```bash
scripts/build-gdpcore.sh
```

也可以只编某几个平台（`macos`、`ios`、`ios-simulator`），xcframework 会包含 `build/gdpcore/` 下已编好的所有平台：

```bash
scripts/build-gdpcore.sh macos
```

日志在 `build/logs/`。

### 3. 运行 GDPKit 测试

```bash
swift test --package-path Packages/GDPKit
```

### 4. 生成 Xcode 工程

```bash
xcodegen generate
```

然后打开 `Spectre.xcodeproj`，选 `Spectre` scheme 运行。也可以在命令行编译 macOS 版：

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
```

### 5. 运行

App 启动后是登录页：输入服务器（`host[:port]`，默认端口 4442）和用户名，按服务器的提示登录，选择桌面后进入会话。首次连接会先让你确认服务器的证书指纹。没有服务器时点 **Try the demo host**（用户 demo，密码 demo），App 内会起一个测试 lobby 和测试 host。见 [docs/login.md](docs/login.md)。

带下面任意命令行参数启动时，会跳过登录、直接播放（开发和测量用）。App 先用 VideoToolbox 现编一段 10 秒的 1080p60 测试码流（约 3 秒），然后循环播放，左上角每秒更新一次解码、显示和会话的统计。工具栏可以切换来源、H.264/HEVC 和呈现节奏。来源有三种：

- **Loopback**（默认）：App 内的测试 host 通过真实的 GDP 会话（QUIC，127.0.0.1）发送测试码流，经 SessionClient 收下后解码显示，StatsReport 再回到 host。见 [docs/session-client.md](docs/session-client.md)。
- **Direct**：测试码流直接交给解码器，不经过网络。
- **Remote**：连接真实的 host（用静态 token 启动的 wraith，§6.11）：

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --connect HOST:PORT --token TOKEN --fingerprint SHA256
```

测量模式（预热 2 秒后测 N 秒，打印统计后退出）：

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

可选参数：`--source loopback|direct`、`--codec h264|h265`、`--mode onArrival|displayLink`、`--in-flight <N，0 为不限>`、`--screen <屏幕序号>`、`--rate <display link Hz>`、`--min-present-ms <ms>`。

SpectreKit 的测试（包括 H.264/HEVC 彩条的端到端色彩校验）：

```bash
swift test --package-path Packages/SpectreKit
```

### 6. iOS / iPadOS

`scripts/build-gdpcore.sh` 默认就会编 iOS 和模拟器的 slice。在 iPad 模拟器上跑两个包的测试：

```bash
(cd Packages/GDPKit && xcodebuild test -scheme GDPKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-GDPKit)
```

```bash
(cd Packages/SpectreKit && xcodebuild test -scheme SpectreKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-SpectreKit)
```

编译 App 并安装到模拟器：

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --bench 10 --codec h265
```

在模拟器里 VideoToolbox 是软件解码，而且没有 `presentedTime`，所以模拟器上的耗时数字不能和真机或 macOS 比较，见 [docs/prototype-findings.md](docs/prototype-findings.md)。在真机上运行需要在 Xcode 里给 target 选一个开发者 Team。

## 许可证

MIT，见 [LICENSE](LICENSE)。libgdp 为 MIT；ghost 的其余部分（含 spectre 客户端）为 GPL-3.0-only，本项目不复制其代码。
