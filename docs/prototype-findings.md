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

## 风险 1：Swift 调用 libgdp（GDPKit）——通过

### 结论

libgdp 及其依赖用 vcpkg 静态编译，和一层 C ABI（`Packages/GDPKit/Native/include/gdpcore.h`）一起合并成一个静态库，打包为 `GDPCore.xcframework`。Swift 端 `GDPKit` 只 `import GDPCore`（纯 C 模块），不开 C++ interop。Swift Testing 的 18 个测试全部通过（`swift test --package-path Packages/GDPKit`），都调用 libgdp 的真实代码：

| 测试组 | 覆盖的 libgdp 功能 |
|---|---|
| Fingerprints (§2.3) | `sha256`（NIST 向量，含 100 万个 `a`）、`sha256_hex`、`is_sha256_hex`（只接受小写 64 位）、`format_fingerprint` |
| Control-stream framing (§3.1) | `encode_frame` 的线上字节、`FrameReader` 在任意分块和逐字节输入下拆出同样的帧、超长长度前缀报 `FRAME_TOO_LARGE`(12)、§6.3 认证前的 16 KiB 上限、坏 protobuf 报 `MALFORMED_FRAME`(11) |
| Video datagrams (§9) | 16 字节头的线上布局（含 `host_lat` 按 10 µs 取整）、`slice_payload_for`、`slice_video_frame` 切片后乱序加重复送入 `VideoFrameReassembler` 能拼回原帧、新 `frame_id` 丢弃未完成的旧帧 |
| QUIC transport | 进程内回环的真实 QUIC 连接（下详） |

QUIC 回环自检（`gdpc_selftest_quic_loopback`）：用 OpenSSL API 现场生成 P-256 自签名证书，libgdp `Transport::listen` + `connect`，核对客户端看到的证书指纹，打开 control/input 两个流，控制流上 Ping/Pong 往返，服务端把一个 48 KiB 的视频帧切成 datagram 发过来，客户端重组后逐字节比对。macOS 上一次典型结果：握手 5.2 ms，RTT 506 µs，路径 MTU 探测后最大 datagram 1432 B，收到 35 个分片。这一项证明 ngtcp2 + OpenSSL 的静态库在当前平台真的能跑，第 3 步在 iOS 模拟器上复用。

### 为什么用 C ABI，而不是 Swift/C++ interop

实测见 `experiments/CxxInteropProbe/`（Swift 6.4，`-cxx-interoperability-mode=default`，直接导入 libgdp 头文件，不改上游）：

| 项目 | 结果 |
|---|---|
| 返回 `std::string` / `std::array` 的普通函数（`sha256_hex`、`format_fingerprint`） | 可用 |
| POD 结构体 + 指针出参（`VideoDatagramHeader::decode`） | 可用 |
| `std::function` 参数（`slice_video_frame`）| **不可用**：Swift 闭包（捕获或不捕获）都不能转换成 `std::function` |
| `std::function` 成员（`LobbyClient::on_error`、`Connection::on_datagram`、`Stream::on_data`……） | **不可用**：不能赋值 Swift 闭包。libgdp 的所有回调都是这种形式 |
| 不可拷贝也不可移动的类（`Transport`、`Connection`、`Stream`、`LobbyClient`） | **默认根本不导入**。外挂 API notes 标成引用类型后能导入，但 libgdp 没有引用计数，只能标 immortal，对象永远不释放；而且 API notes 只在手写 module map 旁边才会被 clang 找到 |
| 抽象类 `ClientConnection`（纯虚 `on_connected()`） | Swift 不能继承 C++ 类，所以 SessionClient 只能用 C++ 写 |
| protobuf 生成的消息（`gdp::session::ControlEnvelope`） | **swift-frontend 6.4 直接崩溃**（在 `session.pb.h` 上做名字查找时） |

另外，C++ interop 会向上传染：导入 C++ 模块的 Swift 模块要开 interop，它的使用者（SpectreKit、App）通常也得开。

所以：协议状态机和热路径（datagram 重组、protobuf、以后的 SessionClient 和 StatsReport）留在 C++，Swift 只通过粗粒度的 C 接口和它打交道（不透明句柄 + C 函数指针回调 + `void *ctx`）。不选 Objective-C++ 是因为每个 datagram 都要走 `objc_msgSend` 和 `NSData` 分配，还会引入 ObjC 运行时。

### 构建方式和取舍

- **vcpkg**：自带清单 `scripts/vcpkg/vcpkg.json`，只有 libgdp 的 4 个依赖（`ngtcp2[openssl]`、`openssl`、`protobuf`、`zstd`），`builtin-baseline` 固定在 `07f48122`。overlay triplet `arm64-{osx,ios,ios-simulator}-spectre`：静态库、只编 release、最低系统 27.0。`arm64-osx-spectre` 同时作为 host triplet（`protoc`）。每个 triplet 单独一个 install root（`build/vcpkg/<triplet>`），因为 manifest 模式会删掉同一 install root 里不属于本次 triplet 的包。首次编译 macOS 依赖约 1.3 分钟（protobuf 37 s、OpenSSL 20 s）。
- **libgdp 不改一行**：`Native/CMakeLists.txt` 用 `add_subdirectory(third_party/ghost/libgdp EXCLUDE_FROM_ALL)`，只构建 `gdpcore` 依赖到的 `gdp` 目标。上游的测试程序是无条件声明的，`EXCLUDE_FROM_ALL` 让它们不参与构建（iOS 上也跑不了）。
- **合并静态库**：`libtool -static` 把 `libgdpcore.a`、`libgdp.a`、protobuf、abseil、utf8_range、ngtcp2、OpenSSL、zstd 合成一个 `libGDPCore.a`，xcframework 的 Headers 里只有 `gdpcore.h` 和 `module.modulemap`。不放 `libprotoc`、`libupb`（编译器用的），也不放 `libprotobuf-lite`（和 `libprotobuf` 符号重复）。
- **体积**：macOS slice 33 MB（RelWithDebInfo，含调试信息；最终链接进 App 时只取用到的目标文件，并会被 strip）。
- **链接**：Swift 端需要链接 libc++（`Package.swift` 的 `linkedLibrary("c++")`）。

### 踩过的坑

- macOS 自带 bash 3.2 在 `set -u` 下展开空数组 `"${a[@]}"` 会报 unbound variable，要写成 `${a[@]+"${a[@]}"}`。
- SwiftPM 自动生成的 module map 在 `.build` 里，旁边的 `.apinotes` 不会被 clang 加载，要自带 `module.modulemap`。

### 已知问题（留给后续）

- `libgdp/src/transport/tls.cpp` 在 `__APPLE__` 下从 `/etc/ssl/cert.pem` 读系统根证书。iOS 沙盒里没有这个文件，`CaTrust::system` 在 iOS 上不起作用。只影响用 CA 证书的 lobby（§2.3），固定指纹的会话连接不受影响。不改上游的解决办法：把根证书导出成 PEM，通过 `CaTrust::extra_file` 传入。
- 会话层 `SessionClient` 上游是 GPL-3.0，要照 gdp-spec 用 C++ 重写，放在 `Packages/GDPKit/Native`，通过 C ABI 暴露。
