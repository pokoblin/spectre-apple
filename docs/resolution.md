# 远端分辨率跟随窗口

连接真实 host 时，远端桌面的大小跟着 Spectre 的会话视图走：macOS 上是窗口（包括全屏），iPad/iPhone 上是整个屏幕区域（包括旋转、分屏、台前调度）。不再留黑边，也不再缩放。工具栏的 **Resolution** 菜单里有两个开关，都会记住：

- **Match Window Size**：默认开。关掉后不再发请求，远端保持当前大小，画面像以前一样按比例显示。
- **Retina Resolution**：默认关，按点请求；打开后按像素请求（点 × 缩放比例）。

测试源（Loopback、Direct）的测试流是固定的 1080p，所以只有 `source == .remote` 的会话才会跟随。

## 协议

- **§6.2 `SessionHello.displays`**：连接时（包括自动重连）就带上视图当前的尺寸，第一帧直接是这个大小，不用连上之后再让 host 重开一次编码器。host 只看第一项的宽和高，`SessionAccept.outputs` 报告它实际用的尺寸；做不到不算错误。
- **§7.2 `ResolutionChange` / `DisplaysChanged`**：会话中尺寸变了就发 `ResolutionChange`。host 对每个请求都回一个 `DisplaysChanged`，内容是改完之后的输出列表，不管改没改成。宽高必须是偶数（4:2:0 色度二次采样需要），每边 320–8192，否则 host 拒绝并回当前尺寸。

GDPKit 原来就有这两样（`Configuration.display`、`GDPSession.requestResolution`），它的测试也覆盖了 Hello 里的尺寸、合法和奇数尺寸的请求。这次改动没有碰 GDPKit 和 C ABI，不用重建 GDPCore。

## 什么时候请求、请求多大

逻辑在 `SpectreKit/Session/ResolutionFollower.swift`，是一个不碰 UI 的值类型。时间由调用方传入，和 `TouchPointerMapper` 一样，所以测试不用真的等待。

- **尺寸**：视图的点数，开了 Retina 就乘以缩放比例，然后向下取整：宽度取到 16 的倍数，高度取到偶数，再夹到 320–8192。§7.2 只要求偶数；宽度多取到 16 的倍数，是为了绕开 wraith 的花屏问题（见下面“踩到的坑”）。Mac 上 1512×945 点的窗口按点是 1504×944，按像素是 3024×1890；iPhone（3 倍）430×932 点按像素是 1280×2796。宽度最多少 15 像素，画面左右各留几像素黑边。
- **防抖**：wraith 每次改尺寸都要关掉编码器再重开（`handle_resolution_change()`：`close_encoder()` 后 `set_session_codec()`，失败就退回旧尺寸），代价不小。所以视图尺寸变化后要稳定 0.5 秒（`settleDelay`）才发；拖动窗口时每次变化都会重新计时，松手后只发一次。
- **不重复请求**：和输出当前的尺寸相同、或者和上次请求的尺寸相同，都不发。host 改不了尺寸时（比如会话不支持改大小），它会回当前尺寸；如果再请求一次同样的尺寸，得到的还是同样的回答。窗口换到别的尺寸时才会再请求。
- **Hello 也算请求过**：`sizeForConnection()` 把这次连接的尺寸记为已请求。host 不接受 Hello 里的尺寸时，客户端不会紧接着再发一次 `ResolutionChange`。
- **打开开关、切换点/像素、换到缩放比例不同的显示器**：都按“尺寸变了”处理，稳定后请求一次。

## App 里怎么接

- **测量**（`ContentView.swift`）：
  - macOS 量 `VideoView` 本身，它在工具栏下面，量出来就是画面实际能用的区域。
  - iOS 量铺满全屏的黑色背景。`VideoView` 在触摸键盘弹出时会缩到键盘上方（让画面不被挡住），如果量它，每次开关键盘都会让远端改一次分辨率。
  - 缩放比例用环境里的 `displayScale`，窗口移到另一个显示器时会跟着变。
- **`PlaybackModel`**：每次连接都经过 `connect(_:)`（登录、`--connect`、重连都走这里），在这里把尺寸写进 `config.display`。所以 `LoginFlow` 和 `RemoteSession` 都不用改。`onPictureChange`（SessionAccept 和每个 DisplaysChanged）把 host 报告的尺寸告诉 follower。计时器到点时只有会话已建立（`phase == .playing`）才发；没建立时请求保持挂起，连上后再处理。
- 日志里有 `session: asking for W×H`（Hello 或 ResolutionChange）和 `session: output W×H`（host 报告的尺寸）。

## 踩到的坑

- **wraith 在宽度不是 16 的倍数时花屏**（N100 上的 vaapi HEVC）：画面整体向一侧斜着错位，像是行跨度算错了。在真实 host 上逐个试宽度（高度都是 460）：808、824、856 花屏；768、816 正常；高度 460 本身不是 16 的倍数，但没有问题。客户端这边没有问题：`decodedBarsRenderTheirColours` 现在也用 824×460 和 856×460 跑（VideoToolbox 编码，H.264 和 HEVC 都跑），在色条区域的上下两处取样颜色都对，说明解码和渲染能正确处理这类宽度（编码时补齐到 16 的倍数，再按 conformance window 裁掉）。所以问题在 host 的采集或编码上。我在这边跑不了 host，具体是哪一步没有确认。客户端的做法是只请求 16 的倍数的宽度（`ResolutionFollower.widthAlignment`）。
  - **在 host 端修复后复测**（2026-10-15）：在 fork 的 ghost 里修了 wraith，装到同一台 host 上，再用临时去掉对齐的客户端（只要求偶数）请求 990、856、824、808 宽（高度 566），画面都正常，修复有效。
  - **对齐先保留**：上游现成的 wraith 用 vaapi 时仍会花屏，而客户端没法知道 host 有没有这个修复：协议里没有版本号，`SessionAccept.encoder` 要连上之后才知道，Hello 里的尺寸在那之前就发出去了。保留的代价只是宽度最多少 15 像素。等上游合并修复并发布新版本后，把 `widthAlignment` 改回 2，再改对应的测试和这里的说明。
- **macOS 上连接时会多改一次尺寸**：第一次量尺寸时工具栏还没布局好，Hello 里请求的高度多出 20 点（856×480），工具栏出现后又发了一次 `ResolutionChange`（856×460）。结果是会话开始时 host 的编码器多重开了一次，画面没有问题。
- **Retina 模式下远程桌面的界面很小**：按像素请求时，GNOME 拿到的是 3840×2056 这样的尺寸，但仍按 1 倍缩放显示。`DisplayDescriptor.scale` 这一项 host 会忽略（§6.2：只看宽和高），所以需要用户自己在远程桌面里把缩放设成 200%。这也是默认按点请求的原因之一。

- **iOS 上 `onGeometryChange` 的尺寸不含安全区**：即使挂在 `.ignoresSafeArea()` 之后，`proxy.size` 也是扣掉安全区之后的大小。iPad Pro 11-inch 竖屏量出来是 834×1158，屏幕实际是 834×1210（上面的状态栏、下面的 Home 指示条一共 52 点）。现在把 `proxy.safeAreaInsets` 加回去，Hello 里是 834×1210。
- **测试 host 的画面会被裁切**：GDPKit 的测试 host 收到合法的 `ResolutionChange` 会照改并回 `DisplaysChanged`，但它发的测试流仍是 1080p，所以客户端按新的尺寸从左上角裁切显示，看起来只剩一部分。真实 host 发的帧本身就是新尺寸，不会这样。它也不会照 Hello 里的尺寸改大小（只记录下来），所以连上后输出仍是 1920×1080。

## 验证

**单元测试**（`ResolutionTests`，16 个）：点和像素的换算、取偶、宽度取到 16 的倍数、夹到 320–8192、空视图；稳定 0.5 秒才请求、拖动中重新计时、只请求一次；和输出相同不请求、被拒绝后同样的尺寸不再请求、换回之前的尺寸会请求；关掉不请求、打开立即按当前视图请求、切换点/像素、缩放比例变化；Hello 带上尺寸后不再重复请求。

**macOS（Debug，连接 scratchpad 里独立运行的测试 host，`--connect`；这时宽度还只取偶数）**：

| 操作 | App 日志 | 测试 host 看到的 |
|---|---|---|
| 连接，窗口 1280×760 点 | `asking for 1280×708`（工具栏下面的区域） | Hello 1280×708，没有 ResolutionChange |
| 拖窗口角缩小 | `asking for 1000×568`，`output 1000×568` | 第 1 个请求 1000×568 |
| 打开 Retina Resolution | `asking for 2002×1138` | 第 2 个请求 2002×1138 |
| 关掉 Retina | `asking for 1000×568` | 第 3 个 |
| 关掉 Match Window Size 后缩小窗口 | 没有请求，画面按比例显示 | 没有新请求 |
| 重新打开 Match Window Size | `asking for 856×460` | 第 4 个 |

关掉 Match Window Size 后，菜单里的 Retina Resolution 是灰的。

**iPad 模拟器（iPad Pro 11-inch (M5)，iOS 27.0，同一个测试 host）**：Hello 是 834×1210；打开触摸键盘后画面缩到键盘上方，没有发出 `ResolutionChange`。简体中文界面下菜单显示为“匹配窗口大小”“Retina 分辨率”和说明文字。

**macOS 连接真实 host**（Ubuntu 26.04 + GNOME，Intel N100，wraith 用 vaapi 编码 HEVC；用保存的登录连接）：

| 操作 | 请求的尺寸 | 结果 |
|---|---|---|
| 连接，窗口 824 点宽 | Hello 816×480，随后 816×460 | host 照 Hello 的尺寸开始，画面正常 |
| 全屏 | 1920×1028 | 铺满屏幕，画面正常 |
| 全屏下打开 Retina Resolution | 3840×2056 | host 照改，画面正常，但 GNOME 界面变得很小（见上面） |
| 关掉 Retina、退出全屏 | 1920×1028，然后 816×460 | 正常 |
| 拖窗口角放大 | 1056×618（拖动中没有请求，松手后一次） | 正常 |
| 拖窗口角缩小 | 976×566 | 正常 |

宽度取到 16 的倍数之前，同一台 host 上 856×460 等宽度会花屏，过程见上面“踩到的坑”。

**还没验证的**：

- 改尺寸时编码器重开要多久（日志没有时间戳，没有测量；每次操作后等 3 秒再看，画面都已更新）；会话不支持改尺寸时 host 的回答。
- 模拟器面板没有 Simulator App 窗口，没法用菜单旋转，iPad 旋转、分屏、台前调度都还没试；iPhone 和 iPad 真机都没试。
