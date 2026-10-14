# 原型验证结论

原型验证三个关键风险：

1. Swift 能调用 libgdp（GDPKit）
2. VideoToolbox 解出的帧零拷贝交给 Metal 显示
3. libgdp 能交叉编译成 iOS 版

## 环境

- Apple M4 Pro，macOS 27.0.1，Xcode 27.0（Swift 6.4）
- 上游 ghost `1f0d0c604e1ae8d67252a61f259ff498a049827c`
- vcpkg `07f4812200df3d3c931c0c8a6081d3b21fe2bf9f`（ngtcp2 1.25.0、OpenSSL 3.6.4、protobuf 6.33.4）

## 许可证

本项目 MIT。上游 `client/spectre/`（含 `SessionClient`、着色器）和 `host/gdpnet` 是 GPL-3.0-only，不复制、不移植；会话层照 `docs/spec/gdp-spec.md` 自行实现。libgdp 本身是 MIT，可以直接链接。
