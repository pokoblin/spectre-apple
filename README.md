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
| `third_party/ghost/` | 上游 ghost（git submodule，只读） |

## 从零构建

（随原型各步骤补全）

```bash
git clone --recurse-submodules <this repo> spectre-apple
```

```bash
xcodegen generate
```

## 许可证

MIT，见 [LICENSE](LICENSE)。libgdp 为 MIT；ghost 的其余部分（含 spectre 客户端）为 GPL-3.0-only，本项目不复制其代码。
