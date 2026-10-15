# 连接保活（QUIC keep-alive）

用户在 lobby 的提示框（例如密码框）上停留超过约 30 秒后再提交，登录会失败，报 `Connection closed before completing login: connection error (Timer expired)`。原因是 libgdp 的 QUIC 空闲超时为 30 秒，两端都一样（`third_party/ghost/libgdp/src/transport/quic_conn.cpp` 的 `kIdleTimeout`）；而等待用户输入时，连接上双方都没有数据要发。

gdp-spec §2.1 规定：viewer 在线但空闲时，会话连接 SHOULD NOT 超时；需要流量来维持连接的一方 SHOULD 发送 QUIC PING。§13.1 的表格里，host 通道用的 PING 间隔是 10 秒。

## 做法

libgdp 提供了 `gdp::Connection::set_keep_alive(interval_ms)`（`transport.hpp`），底层是 ngtcp2 的 keep-alive：连接静默满 `interval_ms` 时由 QUIC 自动发一个 PING。默认值 0 表示关闭，GDPKit 原来没有调用过它。

现在客户端的连接都开启了 10 秒间隔的保活，常量 `kKeepAliveMs` 定义在 `Packages/GDPKit/Native/src/keep_alive.hpp`：

- **lobby 连接**：`lobby_api.cpp` 的 `gdpc_lobby_connect` 在 `LobbyClient::connect()` 成功后立刻开启。`set_keep_alive` 和建立连接一样，是投递到网络线程按顺序执行的；建立连接那一步同步创建 ngtcp2 连接，所以紧接着调用一定会作用到这条连接上。

C ABI（`gdpcore.h`）没有变化，间隔不对 Swift 暴露。改动在 C++ 里，Swift 链接的是预编译的 GDPCore.xcframework，所以仍要用 `scripts/build-gdpcore.sh` 重建全部三个 slice。

## 断线检测

保活不会掩盖真正的断线：对方不再响应时，PING 得不到回应，空闲计时器照样会到期。但到期时间会推迟。按 RFC 9000 §10.1，收到对方最后一个包之后，**第一个** ack-eliciting 的发送会把空闲计时重新从头算起。PING 属于 ack-eliciting，于是：

- 连接本来空闲（例如停在 lobby 的提示框上）时断网：最后一次收包后约 10 秒发出 PING，计时从那时重新开始，断线在约 **40 秒**后报告。测试实测为 40.0 秒。
- 断网前后本来就有我方在发数据：计时在断网后的第一次发送时重新开始，PING 不会再额外推迟，断线仍在约 30 秒后报告。

## 测试（GDPKit，`Lobby keep-alive`）

- `aPromptLeftOpenPastTheIdleTimeoutStillTakesItsAnswer`：测试 lobby 发出 Password 提示后，等 35 秒再回答，登录照常拿到 Redirect。测试 lobby 收到的回答是 `demo`，而且全程只有一条连接。没有保活时，这个测试在 30.0 秒时以上面那条 `Timer expired` 失败。
- `aLobbyThatGoesAwayDuringAPromptIsReported`：经 `UDPRelay` 连到测试 lobby，停在提示框上时 `relay.cut()`。客户端仍然报告失败（code 0，`Timer expired`），实测 40 秒，测试窗口为 50 秒。

`LobbyScript` 新增了 `answerDelay` 参数：它模拟用户在每个提示上花的时间，`nil` 表示永远不回答。
