# spectre-apple

[ghost](https://github.com/jsaiko/ghost) 远程桌面的 Apple 原生客户端（macOS / iOS / iPadOS），显示名 **Spectre**，Bundle ID `org.ghost.spectre.apple`。

- 协议层：上游的 C++ libgdp（ngtcp2 + OpenSSL + protobuf + zstd），编译成静态库打包为 xcframework，通过一层 C ABI 暴露给 Swift。
- 平台层：Swift、SwiftUI、Metal、VideoToolbox。

当前处于**原型阶段**，验证结论见 [docs/prototype-findings.md](docs/prototype-findings.md)。

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

## 许可证

MIT，见 [LICENSE](LICENSE)。libgdp 为 MIT；ghost 的其余部分（含 spectre 客户端）为 GPL-3.0-only，本项目不复制其代码。
