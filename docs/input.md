# 输入：键盘、鼠标、触摸

照 `third_party/ghost/docs/spec/gdp-spec.md` §8.1–§8.3 和 §7.4 自行实现。上游的行为（快捷键、捕获模式）只参考了设计文档：`docs/design/spectre-client.md` 的 "Session window and input" 和 `packaging/macos/README.md` 的 "Keys"。没有读过、也没有移植 `client/spectre`、spectre-qt 的代码（GPL-3.0），按键映射表是照 USB HID Usage Tables（Keyboard/Keypad page 0x07）和 Apple 公开的键码常量（Carbon 的 `kVK_*`）写的。

![iPad 模拟器上的触控板模式：Metal 画的 host 光标、工具栏的 Capture Mouse 和 Trackpad、host 收到的输入](images/ipad-trackpad-mode.jpg)

## 分层

```
App/Shared/PlaybackModel           会话建立后创建 SessionInput，结束时先释放按键再断开
  └ SpectreKit/Input
      ├ MacSessionView (macOS)     MTKView 子类：本地事件监听（键盘）、鼠标事件、cursor rect、捕获
      ├ IOSSessionView (iOS)       MTKView 子类：UIPress、悬停、.indirectPointer 触摸、滚动、指针锁定 + GCMouse、手指
      ├ TouchPointerMapper         手指 → 指针的手势状态机（直接触摸 / 触控板两种模式）
      ├ SessionInput               一个会话的输入状态：host 光标、画面尺寸、捕获模式
      ├ ScrollConverter            滚动量 → notch
      ├ PointerMapping             视图坐标 ↔ 画面 0..1（含黑边）
      ├ InputSender                记录已按下的键和鼠标键，releaseAll()；丢掉自动重复
      ├ MacKeyCodes / HIDUsage     kVK → HID usage
      └ LocalShortcut              留在本地的快捷键
          └ GDPKit.GDPSession      sendKey / sendPointer*（任意线程，切到会话队列）
```

## 键盘

**按物理位置**（§8.2）：macOS 用 `NSEvent.keyCode`（`kVK_*`，物理位置）查表得到 HID usage，host 按自己的键盘布局解释。字符、输入法都不参与。

- **修饰键**：左右键用 `modifierFlags` 里与设备相关的位（IOKit `NX_DEVICE*KEYMASK`）区分。每个带修饰键状态的事件（`flagsChanged`、keyDown/keyUp、鼠标按键、滚轮）都按它的标志位把 8 个修饰键的状态整体同步一遍（`MacKeyCodes.modifierStates`），而不是只处理“变化的那个键”：`flagsChanged` 可能丢失。实测：在会话窗口里按 Shift+Cmd+Ctrl+4 截图，macOS 的截图界面会接管键盘，松开时只补一个 keyCode 为 0、标志全为 0 的 `flagsChanged`；原先的实现认不出它，Shift、Super、Ctrl 就一直按在 host 上。之后按 Super 实际上是 Ctrl+Shift+Super（不打开活动概览），滚轮带着 Ctrl，拖动也带着修饰键。没有设备位的合成事件（某些自动化工具）保留已按下的一侧。Caps Lock 每次切换只报一次 `flagsChanged`，所以每次都发一次按下加松开。fn 键没有 0x07 页的 usage，不转发；fn 和方向键组合时，macOS 已经把 keyCode 换成了 Home/End/PageUp/PageDown，可以照常转发。
- **Cmd 作为 Super**（左右 GUI 键），和上游一致：远端的复制、粘贴仍然是 Ctrl+C、Ctrl+V。
- **自动重复**：`isARepeat` 的 keyDown 丢掉，由 host 的合成器自己重复。InputSender 也会丢掉“已经按下的键再次按下”和“没按下的键松开”（例如获得焦点之前就按住的键）。
- **为什么用本地事件监听**：AppKit 不会把“按住 Cmd 时按下的键”的 keyUp 交给 view，Cmd 组合键也会先送到菜单。所以 MacSessionView 用 `NSEvent.addLocalMonitorForEvents` 截获 keyDown/keyUp/flagsChanged，只有当它是 key window 的第一响应者时才处理，窗口里的其他文本框照常输入。
- **ISO 键盘**：在 ISO 键盘上，macOS 报告的 `kVK_ISO_Section` 和 `kVK_ANSI_Grave` 与物理位置是对调的，按当前键盘类型（`KBGetLayoutType`）换回来，见 `MacKeyCodes`。

### 留在本地的快捷键

只保留三个，按字符匹配（和系统一样：AZERTY 上的 Cmd+Q 在 QWERTY 的 A 位置），其余 Cmd 组合键都作为 Super+X 转发：

| 快捷键 | 作用 |
|---|---|
| Ctrl+Cmd+G | 捕获或释放鼠标（上游 macOS 客户端的绑定，Mac 键盘没有 Scroll Lock） |
| Ctrl+Cmd+F | 全屏 |
| Cmd+Q | 退出（交给 App 菜单） |

Cmd+Tab、Cmd+Space、Mission Control 等系统快捷键由系统先拦截，到不了 App；App 开着沙盒，不能用会吞事件的 CGEventTap，这次不做全屏下的抓取。切到别的 App 时会释放所有按键，所以不会有键卡住。

### 释放按键（§8.2 SHOULD）

以下情况调用 `releaseAll()`：先松开普通键，再松开修饰键（避免 host 看到修饰键已经松开、普通键还按着，比如 Super+L 变成 L），最后松开鼠标键。

- 窗口失去 key 状态、App 失活、view 失去第一响应者；
- 切换全屏、Cmd+Q 之前；
- 断开、登出之前（在关闭连接之前发出），会话结束、view 离开窗口时。

## 鼠标（macOS）

**绝对模式**（默认）：`mouseMoved`/`*Dragged` 的位置经 `PointerMapping` 换成画面上的 0..1，作为绝对移动发出（§8.2）。落在黑边上的点夹到画面边缘，所以指针能顶到远端屏幕的边。和上一次相同的位置不重复发送。只在 key window 里跟踪移动（tracking area 的 `.activeInKeyWindow`）；`acceptsFirstMouse` 为真，点击非活动窗口时这次点击也会转发。按键之前先把指针移到点击位置。

**按键**：AppKit 的 `buttonNumber` 映射成 Linux `BTN_*`：0 → `BTN_LEFT` 0x110，1 → `BTN_RIGHT` 0x111，2 → `BTN_MIDDLE` 0x112，3 → `BTN_SIDE` 0x113（后退），4 → `BTN_EXTRA` 0x114（前进），5–7 → `BTN_FORWARD`/`BTN_BACK`/`BTN_TASK`。Ctrl+点击不会变成右键：Ctrl 已经作为按键转发，远端收到的就是 Ctrl+左键。

**滚轮**：§8.2 的单位是 notch，向右、向下为正，平滑设备发小数；客户端负责自己的“自然滚动”设置。AppKit 的 `scrollingDeltaX/Y` 表示内容的移动方向（Y 为正表示内容下移，也就是向上滚），并且已经按系统的“自然滚动”设置处理过，所以 `ScrollConverter` 只需要取反、换单位：

- 带刻度的滚轮（`hasPreciseScrollingDeltas == false`）：delta 的单位是行，1 行 = 1 notch。快速转动时系统加速给出的多行照样转发。
- 触控板、Magic Mouse（精确 delta，单位是点）：25 点 = 1 notch，发小数。Linux 桌面上 1 notch 大约滚 3 行（约 50 像素），25 点在 Retina 屏上正好也是 50 像素。
- 惯性阶段（`momentumPhase`）照样转发，因为 host 不会自己做惯性。

**捕获模式**：给游戏和 3D 视图用，相对移动（§8.2）。Ctrl+Cmd+G 或工具栏的 Capture Mouse 按钮切换。

- 进入：把本地指针移到远端指针所在的位置，`CGAssociateMouseAndMouseCursorPosition(false)` 断开指针和鼠标的关联，然后隐藏指针。此后鼠标只产生 delta，点击也留在这个窗口里。
- 相对移动：`deltaX/deltaY`（AppKit 鼠标事件的 delta 向右、向下为正，与 §8.2 相同）除以 `pointsPerVideoPixel`，换成 host 像素。效果是远端光标在屏幕上移动的距离，和本地指针本来会移动的距离一样。
- 光标：只有 host 知道指针在哪里，它用 `CursorPosition` 报告（§7.4），Metal 叠加层把 host 的光标形状画在那里。host 报告之前，先画在最后一次绝对移动的位置。
- 退出：Ctrl+Cmd+G，或者窗口失去 key 状态、App 失活、会话结束。退出时恢复关联，把本地指针移到 host 指针所在的位置，再显示指针；下一次绝对移动一定会发出（相对移动已经改变了 host 指针的位置）。
- 沙盒里可以用 `CGAssociateMouseAndMouseCursorPosition` 和 `CGWarpMouseCursorPosition`，不需要辅助功能权限。

**测试 host 的指针**：`GDPTestHost` 打开 `simulatePointer` 后，会像 wraith 一样维护一个指针：绝对移动放置它，相对移动按输出像素移动它（夹在画面内），每批相对移动之后回报一次 `CursorPosition`（§7.4）。loopback 默认打开，所以在 loopback 里也能看到捕获模式下的光标移动。

### macOS 实测（loopback）

用 computer-use 驱动 App，看 host 收到的事件（每秒打印到 stdout）：

- 左、右、中键分别收到 0x110、0x111、0x112 的按下和松开，按键之前先收到点击位置的绝对移动；
- 滚轮向下 3 格 → `vertical +3`，向右 2 格 → `horizontal +2`；
- Ctrl+Cmd+G 之后收到相对移动，host 回报的位置上画出了 Metal 光标；再按一次，回到绝对移动。

统计浮层原先会挡住它下面的点击（SwiftUI 的 Text 截获了 mouseDown），已经设为不参与命中测试。

computer-use 合成的鼠标移动是按绝对位置模拟的。指针锁住以后，由它算出的 delta 和真实鼠标不同（方向也可能是反的），所以捕获模式下相对移动的方向和手感，要用真实的鼠标和触控板确认。

## iPadOS / iOS：键盘和指针

**入口改成 UIKit**：系统只问窗口的根 view controller 要不要锁定指针（`prefersPointerLocked`，或者沿 `childViewControllerForPointerLock` 往下问），而 SwiftUI `WindowGroup` 的根是一个 App 不能继承的 hosting controller，SwiftUI 也没有指针锁定的修饰符。所以 iOS 改用 UIKit 入口（`App/iOS/AppDelegate.swift`）：scene delegate 自己建窗口，根是 `RootViewController`（`UIHostingController<ContentView>` 的子类，实现 `PointerLockHost`）。界面还是同一个 ContentView；macOS 仍然是 SwiftUI `App`。

注意：从旧版本（SwiftUI 入口）升级的开发安装，系统会用保存的旧 scene 配置恢复窗口，结果是一片黑屏。卸载重装一次即可。

**硬件键盘**：`pressesBegan/Ended/Cancelled` 里，`UIKey.keyCode` 本身就是 HID usage（`UIKeyboardHIDUsage`），直接转发，左右修饰键是不同的 usage。Ctrl+Cmd+G 切换捕获；Mac 上另外两个本地快捷键（全屏、退出）在 iPad 上没有意义，照常转发。`UIScene.willDeactivateNotification`（切到别的 App、下拉控制中心等）和失去第一响应者时释放所有按键。系统快捷键（Cmd+Tab、地球键等）由 iPadOS 先处理。

**触控板和鼠标**（Info.plist 打开 `UIApplicationSupportsIndirectInputEvents`）：

- 悬停：`UIHoverGestureRecognizer` 的位置作为绝对移动发出。
- 点击：以 `.indirectPointer` 类型的触摸送达，`UIEvent.buttonMask` 是当前按住的键，按位映射：主键 → `BTN_LEFT`，次键 → `BTN_RIGHT`，第 3 键 → `BTN_MIDDLE`，依此类推，和 Mac 的 `buttonNumber` 一样。每个触摸事件都和上一次的按键集合对比，多出来的发按下，少了的发松开；触摸结束或取消时全部松开。
- 滚动：一个只接受滚动的 `UIPanGestureRecognizer`（`allowedScrollTypesMask = .all`，`allowedTouchTypes = []`，手指不会触发它）。每次的 translation 增量按“内容的移动”处理，和 AppKit 精确滚动一样换算成 notch（25 点 = 1 notch）。
- 指针外观：画面上用 `UIPointerStyle.hidden()` 隐藏系统指针，由 Metal 叠加层在客户端放置指针的位置画 host 的光标（iPadOS 的指针只能是路径形状，不能显示 host 的位图）。

**捕获模式**：Ctrl+Cmd+G 或工具栏的 Capture Mouse。根 view controller 请求锁定指针，`GCMouse.current` 提供原始 delta（GameController 的 y 轴向上为正，取反）和按键（左、右、中、辅助键）。捕获期间忽略 `.indirectPointer` 触摸带来的按键，以免和 GCMouse 重复。切换捕获时会先松开所有鼠标键，因为一个来源按下的键，另一个来源永远不会报告它松开。没有鼠标（`GCMouse.current == nil`，比如在模拟器里）时不会进入捕获。iPadOS 只在 App 占满屏幕时才真正锁定指针；没锁住时，相对移动照样发送，只是本地指针还能移出窗口。

### iPad 模拟器实测

- 硬件键盘：输入 "aB"，host 依次收到 a 的按下和松开，然后是左 Shift 按下、b 按下、b 松开、左 Shift 松开。
- 触控板和鼠标：模拟器在无界面模式下运行，自动化工具只能发直接触摸，所以 `.indirectPointer` 点击、悬停、滚动和 GCMouse 捕获这几条路径只是编译通过，**还没有实际运行过**，需要在真机上（或在 Simulator.app 里用 I/O → Input → Send Pointer to Device）确认。

## 触摸 → 指针

§8.3 定义了 `TouchEvent`，但参考 host（wraith）会忽略它，所以手指（和 Apple Pencil）的输入不发 TouchEvent，而是由 `TouchPointerMapper` 翻译成 §8.2 的指针事件：绝对移动、`BTN_*` 按键、notch 滚动。这个状态机不依赖 UIKit，输入是触点和时间戳，输出是动作列表，有 40 个单元测试，其中包括每种模式 2 万步的随机压力测试，检查每次按下都恰好有一次松开、光标始终在 0..1 内。iOS 视图负责喂触点、执行动作，并在 `nextDeadline` 到时调用 `update(at:)`（长按）。

两种模式，用工具栏按钮（Touch / Trackpad）切换，选择会记住。没有选过的话默认是触控板模式（2026-10-15 起；之前默认直接触摸，已经选过的保持原来的选择）。切换时先 `reset()`，松开所有按住的键。

**直接触摸（Touch）**：手指点在哪里，指针就在哪里。

| 手势 | 发给 host 的 |
|---|---|
| 单指轻点（≤ 0.3 秒，移动 < 10 点） | 移到手指按下的位置，左键按下、松开 |
| 0.35 秒内、24 点以内的第二次轻点 | 用上一次的位置（host 才能认出双击；可以连成三击） |
| 单指拖动（长按触发前移动 ≥ 10 点） | 移到按下点，左键按下，跟随手指，抬起时松开 |
| 长按（≥ 0.5 秒没有移动） | 触觉反馈，移到按下点，右键点击 |
| 双指拖动 | 先移到两指中点，再按中点的位移滚动：内容跟着手指走（手指上移 = 向下滚），24 点 = 1 notch，发小数 |
| 双指轻点 | 在两指中点右键点击 |
| 三指轻点 | 在中点中键点击 |

**触控板（Trackpad，默认）**：把屏幕当笔记本的触控板用，光标由客户端画（Metal 叠加层），适合点小目标。

| 手势 | 发给 host 的 |
|---|---|
| 单指移动 | 光标相对移动：手指位移 × 1.5 ÷ 画面尺寸，夹在 0..1，作为绝对移动发出（host 不需要回报位置） |
| 轻点 / 双指轻点 / 三指轻点 | 在光标处左键 / 右键 / 中键点击 |
| 轻点后 0.35 秒内按下再拖动 | 左键拖动（之前那次轻点已经点击过一次） |
| 双指拖动 | 滚动，同上，不移动指针 |

会话开始、拿到画面尺寸时（或者在还没碰过屏幕时切到触控板模式），先把指针放到画面中央并画出光标。原先要等手指第一次移动才发出位置，在那之前光标不显示，第一次轻点会点在 host 指针原来所在的位置，而不是客户端以为的中央。

**细节**：

- 第二根手指在第一根按下后 0.1 秒内落下，就算同一个双指手势。单指移动超过阈值后，要等这 0.1 秒宽限期过去才提交为拖动，提交时一次补齐位移，所以不会先按下左键再改成滚动。
- 手势一旦提交（拖动、长按、滚动），后加的手指都忽略，直到所有手指抬起。
- 触摸被取消（系统手势、来电等）、失去焦点、切换模式时，会松开按住的键。
- 参数（`TouchPointerMapper.Tuning`）：移动阈值 10 点，轻点最长 0.3 秒，长按 0.5 秒，双击间隔 0.35 秒、距离 24 点，24 点 = 1 notch，触控板速度 1.5，多指宽限 0.1 秒。

### iPad 模拟器实测（loopback）

- 直接触摸：轻点 → 移动 + 左键；长按 0.9 秒 → 移动 + 右键；双指上滑 120 点 → 先移到中点，再共向下滚动 5 notch（120 ÷ 24）。Metal 光标画在最后一次触摸的位置。
- 触控板，会话开始（iPad Pro 11 英寸，没有保存过模式，默认触控板）：host 先收到 (0.5, 0.5) 的绝对移动，画面中央画出光标；在别处轻点 → 左键点在中央，没有多余的移动；然后单指向右拖 100 点 → 光标移到 0.680（100 × 1.5 ÷ 834）。
- 触控板：单指向右拖 100 点、向上 20 点 → 光标从 (0.5, 0.5) 移到 (0.645, 0.448)（100 × 1.5 ÷ 1032，20 × 1.5 ÷ 580）；轻点 → 在光标处左键；双指轻点 → 右键。

## 光标（§7.4）

host 不把指针画进视频，只发 `CursorShape`（BGRA 预乘，最大 384×384，0×0 表示隐藏）；客户端发相对移动时，host 还会发 `CursorPosition`。`CursorImage` 校验并转换形状：任一边超过 384、一边为 0 另一边不为 0、字节数与尺寸不符，都按规范忽略；热点夹到图像内。

**两种画法：**

- **系统光标（macOS，绝对模式）**：把形状做成 `NSCursor`，通过 cursor rect 只用在画面区域，黑边上是普通箭头。由系统绘制，没有延迟，跟随本地指针。隐藏形状用透明的 1×1 光标代替，不用 `NSCursor.hide()`（那是全局计数器）。
- **Metal 叠加层**：用于捕获模式（本地指针被锁住、隐藏）和 iPadOS（iPadOS 的指针形状只能是路径，不能是位图）。光标和视频在同一个 render pass 里画，预乘混合（source `.one`，destination `.oneMinusSourceAlpha`），并按 viewport 裁剪。

**缩放**：光标随画面缩放，一个 host 像素占 `PointerMapping.pointsPerVideoPixel` 个点，和画面里的内容一样大。系统光标的长边限制在 8–256 点：画面很小时光标不至于消失，画面很大时也不至于盖住画面。Metal 叠加层按整数倍放大时用 nearest 采样，否则用 linear。

**重绘**：光标在两帧之间变化时（形状变了，或捕获模式下位置变了），presenter 用上一帧加新光标再呈现一次，和解码帧共用同一个合并标志（每个主循环最多画一次），也受在途帧上限约束。这次重绘不计入解码和呈现统计。

**坐标映射**：`PointerMapping` 用和渲染器相同的 `VideoRenderer.fitViewport`（在 drawable 像素里计算和取整），所以指针的黑边和画面的黑边完全重合。落在黑边上的点会夹到画面边缘。

**测试 host 的光标**：测试 host 接受会话后发一个 2×2 的白点；loopback 的 `LoopbackHost` 在每次接受会话后改发一个 25×25 的十字准星，更容易看清。

macOS 实测（loopback，1920×1080 画面显示在约 1280 点宽的窗口里）：指针在画面上时，系统光标是 16.7×16.7 点（25 像素 × 0.667），热点在 (8, 8)；移到画面外变回箭头（28×40）。

## 真实 host 实测（ghost，GNOME，内网）

2026-10-14 第一次连真实的 ghost host（ghostd + wraith，Linux 上的 GNOME，x264 软件编码）：lobby 登录、证书确认、PAM 认证、选桌面、建立会话都一次成功，1920×1080 H.264，QUIC RTT 约 1 ms，没有丢帧。键盘和鼠标都到了远端：按 Super（Mac 上单独按 Cmd）打开了 GNOME 的活动概览，wraith 的日志里有我们的指针移动引起的光标更新。

**看起来像“卡死”的那次**：画面先显示活动概览，随后变成一片纯蓝，点击、打字都没有变化。实际原因：

- GNOME 登录后先打开活动概览；点一下空白处回到桌面。这个账号没有设壁纸，GNOME 用默认的背景色 `#023c88` 铺满。
- 空桌面上点击、打字本来就没有变化，host 只在画面变化时编码新帧（wraith 日志：之后每分钟一帧，是顶栏时钟）。
- 顶栏被 Mac 窗口的标题栏和工具栏挡住了：视频原先一直铺到窗口顶上（`ignoresSafeArea`），所以看起来只有一片蓝。现在 macOS 上视频从工具栏下方开始；iOS 上仍然铺满，iPad 的按钮本来就叠在画面上。

统计浮层原先总是打开，盖住远端桌面的左上角。现在连真实 host 时默认关闭（工具栏按钮随时打开），loopback 和 direct 仍然默认打开，因为在那里看统计和 host 收到的输入就是目的。

**结束会话**：原先直接关掉窗口或退出 App，连接就跟着进程消失了，host 要等 QUIC 的空闲超时（约 25 秒）才发现 viewer 走了。现在：

- 关闭窗口：先松开所有按键，再正常关闭会话；Spectre 只有一个窗口，所以关掉它也就退出了 App（`applicationShouldTerminateAfterLastWindowClosed`）。
- 退出 App（Cmd+Q、菜单）：在 `willTerminate` 里先松开按键，再用 `GDPSession.closeAndWait` 同步关闭，最多等 0.5 秒，让 CONNECTION_CLOSE 赶在进程退出前发出去。测试 host 新增了 `viewerClosed`、`viewerCloseCode`，端到端测试确认 `closeAndWait` 返回时 host 已经收到了错误码为 0 的正常关闭。
- 关闭前先让按键松开发出去：libgdp 的 `Stream::send` 只把数据放进缓冲区，要等网络线程本轮的 flush 才真正发送；紧跟着排队的关闭会在同一轮里先写出 CONNECTION_CLOSE，缓冲区里的数据就丢了（测试里关闭前发的 20 个按键事件，大多到不了 host）。所以 `GDPSession.close()` 会先等两个 RTT（20–250 ms）再关闭。断开按钮、关闭窗口、退出 App 都走这条路。

**App Nap**：会话期间持有一个 `ProcessInfo` activity（`.userInitiatedAllowingIdleSystemSleep` 加 `.latencyCritical`），不让系统在窗口隐藏或被遮住时节流 App 的定时器和队列（StatsReport 每 250 ms 一个，§7.5），但不阻止 Mac 空闲睡眠。实测：在有 60 fps 视频流的 loopback 会话里，即使没有这个 activity，隐藏 60 秒也没有被节流（StatsReport 正好每秒 4 个），因为 App 一直在工作。它防的是远端桌面静止、几乎没有新帧、App 大多空闲的时候。采样时进程状态里的 `N` 是系统给隐藏 App 降低的调度优先级，不是 App Nap。

**输入跟踪**：设置环境变量 `SPECTRE_INPUT_LOG=1` 启动，stdout 会逐条打印收到的 macOS 事件原始值（keyCode、`modifierFlags`、滚轮的 `scrollingDelta`/`delta`、是否精确、phase）和发给 host 的每个事件（`→ key`、`→ move`、`→ button`、`→ scroll`）。上面修饰键卡住的问题就是靠它看出来的。

**拖动时 20 fps**：拖动窗口时 host 每秒只出约 20 帧（客户端解码约 1.5 ms、解码到上屏约 15 ms，每秒发出约 100 次指针移动）。瓶颈不在编码：wraith 的日志里 x264 编一帧平均 6–8 ms（最多 14 ms），而是 `encoder: skipping h264 vaapi backend (renderer has no DRM fd)`：会话用户不在 `render` 组里，GNOME 拿不到 GPU，只能用 llvmpipe 在 CPU 上渲染，拖动时每秒只画得出约 20 帧，VA-API 硬件编码也用不了。上游的安装文档（`docs/install/host.md` 的 "GPU access"）要求有 GPU 的 host 把每个会话用户加进 `render` 组。加进 `render` 组之后，GNOME 改用 GPU 渲染，但 wraith 的 VA-API 编码仍然打不开：它只请求 `VAEntrypointEncSlice`，而 N100（Alder Lake-N）只提供低功耗的 `VAEntrypointEncSliceLP`。我们向上游报告后，作者已经修复（没有全功能入口时改用 `EncSliceLP`）。更新 ghost 后实测（2026-10-15）：会话协商为 H.265、VA-API 硬件编码，拖动窗口稳定在 59–61 fps，0 丢帧，客户端解码约 2 ms、解码到上屏平均约 12.5 ms，拖动时码率最高约 5.5 Mb/s。

**滚轮**：一个普通鼠标（无精确滚动）每格给出带系统加速的小数行数，比如连滚 3 格是 0.1、1.19、4.80；按 §8.2 原样作为小数 notch 发出。

调试过程中排除了“主线程卡死”：对进程采样，主线程在正常等待事件；每秒的统计和发给 host 的 StatsReport 一直在继续。

**和上游设计文档不一致的地方**：`audio-cursor-gamepad.md` 说绝对模式下 wraith 不发 `CursorPosition`，实际上它每处理一次我们的绝对移动都会回报一次位置。我们只在捕获模式下使用 host 报告的位置，所以没有影响。

## 测试

`swift test --package-path Packages/SpectreKit`：macOS 上 92 个，iPad 模拟器上 90 个（有 2 个只在 macOS 上跑：对照 Carbon 键码常量、NSCursor）。与输入相关的有：

- **键码表**（`KeyMapTests`）：每个 kVK 映射到唯一的 usage，ISO 下也一样；在 macOS 上和 Carbon 的 `kVK_*` 常量逐个对照，并检查表里的键码集合正好等于 Carbon 列表；ISO 对调、fn、未知键码、各个修饰键的设备位；在 iOS 上和 `UIKeyboardHIDUsage` 抽查对照。
- **InputSender**：丢掉自动重复和多余的松开，`releaseAll()` 的顺序（普通键、修饰键、鼠标键），Caps Lock 每次切换发按下加松开。
- **坐标映射**：上下黑边、左右黑边、往返换算、还没有画面时的情况。
- **滚动换算**：行和点、符号、不产生负零。
- **光标**（`CursorTests`）：形状校验、热点、CGImage 逐像素读回、NSCursor 的尺寸和缩放上下限，以及两个 GPU 测试（光标的位置、缩放、预乘混合、在黑边处被裁掉）。
- **手势**（`TouchPointerTests`，40 个）：见上文。
- **端到端**（`InputEndToEndTests`，经真实的 GDP 会话连到 `GDPTestHost`）：按键、自动重复、会话结束时释放；绝对移动、按键、两个方向的滚动、捕获后的相对移动和 host 回报的 `CursorPosition`、释放捕获后重新发送绝对位置。
- **GDPKit**：测试 host 的事件日志和指针模拟（`inputArrivesInOrder`、`simulatedPointerReportsCursorPosition`）。

## 没有做的

- 全屏时抓取系统快捷键（Cmd+Tab 等）。这次决定不做；沙盒里也不能用会吞事件的 event tap。
- ~~屏幕软键盘~~：已完成，见 [keyboard.md](keyboard.md)。
- 发送原始的 §8.3 `TouchEvent`：wraith 会忽略它。
- 鼠标灵敏度设置。滚动的“25 点 = 1 notch”和触摸的“24 点 = 1 notch”还没有在真实的 host 上校准过。
- 需要真实设备确认的：macOS 捕获模式下相对移动的方向和手感；iPad 的触控板和鼠标（悬停、点击、滚动、指针锁定、GCMouse）。
- 窗口大小变化时没有重画上一帧（和原来一样，等下一帧）。
