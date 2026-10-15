# 手柄

照 `third_party/ghost/docs/spec/gdp-spec.md` §8.5 自行实现。线上的轴和按钮顺序用了 libgdp（MIT）`gdp/gamepad.hpp` 里固定下来的 SDL3 顺序；上游的行为只参考了设计文档 `docs/design/audio-cursor-gamepad.md` 的 "Gamepads" 一节。没有读过、也没有移植上游 `client/spectre` 的代码（GPL-3.0）。

## 分层

```
App/Shared/ContentView            工具栏：Gamepads 开关，显示转发中的手柄数量和名字
App/Shared/PlaybackModel          每个会话提供 `gamepad`；Accept 里生效后创建 GamepadForwarder，结束时 stop()
  └ SpectreKit/Gamepad
      ├ GamepadForwarder          槽位、去重、失去焦点时全部松开、开关、玩家灯、系统手势
      ├ ControllerDevice          一个 GCController（GamepadDevice 协议的实现）
      └ GamepadMapping            GCExtendedGamepad → 6 个轴 + 26 个按钮
  └ GDPKit.GamepadState           按规范顺序命名的轴和按钮
      └ GDPSession                sendGamepadConnect / sendGamepadState / sendGamepadDisconnect
          └ gdpcore::SessionClient  只在 `gamepad` 生效时、槽位 0–3 时发；轴值夹到范围内
```

## 对照规范

| 规范 | 实现 |
|---|---|
| §8.5 只有 `gamepad` 生效时 | 三种来源（远端、loopback、demo）都在 SessionHello 里提供 `gamepad`。没生效时 C++ 层三种消息一律不发，App 也不创建转发器、不显示开关 |
| §8.5 最多 4 个槽位 | 按接入顺序分配最小的空闲槽位，第 5 个不转发；某个手柄断开后，它的槽位留给下一个接入的。C++ 层再挡一次 ≥ 4 的槽位 |
| §8.5 `GamepadConnect` / `GamepadDisconnect` | 接入时发 Connect（`name` 取 `vendorName`，没有时取 `productCategory`），断开时发 Disconnect。会话开始、或者中途打开开关时，已经接着的手柄补发 Connect |
| §8.5 `GamepadState` 是完整状态 | 每次都发全部 6 个轴、26 个按钮；和上一次发出的完全相同就不发。不做节流（见下） |
| §8.5 摇杆 −1…1 向右、向下为正，扳机 0…1 | GameController 的摇杆 Y 轴向上为正，取反。C++ 层把摇杆夹到 −1…1、扳机夹到 0…1，NaN 发 0 |
| §8.5 面键按位置 | GameController 的 extended profile 本身就规定 A/B/X/Y 排成下/右/左/上的菱形，所以直接对应 south/east/west/north，PlayStation 的叉也是 south |
| §8.2 失去焦点时释放（按键的规则，手柄照做） | App 失去活跃状态时给每个手柄发一次全部松开的状态，回来时再发当前状态。macOS 默认不在后台收手柄事件（`shouldMonitorBackgroundEvents` 为 false），和键盘一致 |
| 客户端断开时 host 移除虚拟手柄 | 会话结束不必另发 Disconnect；`stop()` 照样发（连接已关闭时 GDPKit 会丢掉），并把玩家灯和系统按键还给系统 |

### 映射

| GameController | 线上（§8.5） |
|---|---|
| `buttonA` / `buttonB` / `buttonX` / `buttonY` | 0 south / 1 east / 2 west / 3 north |
| `buttonOptions`（Xbox View、PlayStation Share/Create） | 4 back |
| `buttonHome`（Xbox 徽标、PS 键） | 5 guide |
| `buttonMenu` | 6 start |
| `leftThumbstickButton` / `rightThumbstickButton` | 7 / 8 |
| `leftShoulder` / `rightShoulder` | 9 / 10 |
| `dpad` 上下左右（斜向时两个都按下） | 11–14 |
| `GCXboxGamepad.buttonShare` | 15 misc1 |
| `GCXboxGamepad.paddleButton1`–`4`（Elite 的 P1–P4） | 16 右 1、18 右 2、17 左 1、19 左 2 |
| `GCDualSenseGamepad` / `GCDualShockGamepad` 的 `touchpadButton` | 20 touchpad |
| `leftThumbstick` / `rightThumbstick` | 轴 0–3（Y 取反） |
| `leftTrigger` / `rightTrigger` | 轴 4 / 5 |

Elite 背键的对应是按 SDL 的约定推的：P1、P2 在右手（上、下），P3、P4 在左手；Apple 的文档没写 `paddleButton1`–`4` 分别是哪个，手边也没有 Elite，**没有实测**。misc2–misc6 没有对应的按键，始终是松开。

## 取舍

- **默认关**：工具栏的 Gamepads 开关，记在 UserDefaults 的 `gamepadForwarding` 里。关掉时发 Disconnect，远端的虚拟手柄随之消失；打开时补发 Connect 和当前状态。capability 照样提供，所以中途开关不用重连。
- **玩家灯**：转发期间把手柄的 `playerIndex` 设成槽位号，手柄上的灯显示第几号；停止转发后设回 `.indexUnset`。
- **Home 和 Share 交给远端**：转发期间，把这个手柄上所有绑定了系统手势的元素（`isBoundToSystemGesture`，实际就是 Home 和 Share/Options）的 `preferredSystemGestureState` 设为 `.disabled`，停止转发时恢复原值。代价是会话期间不能用这两个键截图、录屏或打开系统界面。
- **macOS 27 的 Home 键授权**：设为 `.disabled` 还不够。第一次按 Xbox 徽标键时，系统会弹出提示问是否把 Home 键交给 Spectre；用户允许之后才能转发（见实测）。系统设置里的 “Home 键在 App 中的动作” 如果是 “系统默认”，系统会一直自己处理 Home 键，不管 App 的偏好（`GCControllerHomeButtonSettingsManager` 的 `InAppAction`）。
- **不节流**：摇杆一动就是一串状态。实测 Xbox 手柄把摇杆推到底再松开大约产生十个状态，每个 `GamepadState` 不到 100 字节，在 input 流上不是问题，所以先按变化逐个发送。
- **主线程**：GameController 的回调放在主队列（`handlerQueue = .main`），和键盘、鼠标事件一样在主线程上处理，状态都是 `@MainActor` 的，不需要锁。

## 测试

- **GDPKitTests**（新增 6 个测试用例）：Connect、State、Disconnect 原样到达 host，State 总是 6 + 26 个元素，按钮位正确；轴值夹到范围内（NaN、无穷大、超出范围的扳机）；host 或客户端任一方没有 `gamepad` 时三种消息都不发；槽位 4 不发；线上顺序与规范表格逐项对照。
- **SpectreKitTests**（新增 9 个）：
  - `GamepadMapping`：用 `GCController.withExtendedGamepad()` 造的快照手柄，摇杆方向和扳机范围；每个按键只点亮自己那一位；十字键斜向时两个方向都按下。快照手柄的十字键要用 `setValueForXAxis` 设，单独给方向按钮 `setValue` 不起作用。
  - `GamepadForwarder`：用假设备和记录用的 sink：默认关；已接入的手柄补发 Connect；每次变化发完整状态、相同的不重发；最多 4 个槽位、空出的槽位复用、断开的手柄不再转发；失去焦点时全部松开、回来时发当前状态；中途开关；玩家灯和系统手势的设置与恢复。设置用独立的 `UserDefaults(suiteName:)`。

## 实测

**macOS，Xbox Wireless Controller（蓝牙），loopback**：

- 接入后 host 收到 `gamepadConnect(slot: 0, name: "Xbox Wireless Controller")` 和初始状态，工具栏显示 “Gamepads (1)”。
- 逐个按键核对，全部正确：A/B/X/Y → south/east/west/north，LB/RB → 9/10，View → back，Menu → start，两个摇杆按下 → 7/8，十字键 → 11–14，Share → misc1。
- 轴：左右摇杆推到最右，X 为 1；推到最下，Y 为 1（取反正确）；LT、RT 为 0…1。
- Xbox 徽标键：第一次按下时系统弹出授权提示，那两次都没到 Spectre（另一个用 `shouldMonitorBackgroundEvents` 在后台监听的小工具也没收到，说明被系统拿走了）；允许之后再按，按下和松开都转发成 guide。
- Share 键（会触发系统截图的那个）不需要授权，直接转发成 misc1。
- 工具栏开关：关掉时 host 收到 `gamepadDisconnect(slot: 0)`，再打开时收到 Connect 和全部松开的当前状态；UserDefaults 随之变化。
- 沙盒 App 不需要额外的 entitlement 就能用蓝牙手柄。

**iPad 模拟器**：这个 Xcode 27 环境没有独立的 Simulator 应用，Mac 上接的手柄转不进模拟器。模拟器里始终有一个自带的 `'MFi'/'Gamepad'` 虚拟手柄（应用一启动就在，不发任何输入），Spectre 正常为它分配了槽位 0、发出 Connect 和初始状态，iOS 这条路径的接入部分是通的；按键和摇杆的转发要在真机上确认。

**没有在真机上验证的**：PlayStation 手柄的触控板按下、Xbox Elite 的背键、Switch Pro 手柄的面键位置、iPad 真机。

## 没有做的

- §8.6 `hid`（原始手柄）：iOS 上没有办法打开手柄的 HID 接口，macOS 上也要额外的权限；标准手柄是规范定义的兜底方式。
- 震动、体感、触控板坐标、灯条：§8.5 的标准手柄没有这些字段，host 也没有回传通道。
- iPad 屏幕上的虚拟手柄（`GCVirtualController`）。
