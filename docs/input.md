# 输入：键盘、鼠标、触摸

照 `third_party/ghost/docs/spec/gdp-spec.md` §8.1–§8.3 和 §7.4 自行实现。上游的行为（快捷键、捕获模式）只参考了设计文档：`docs/design/spectre-client.md` 的 "Session window and input" 和 `packaging/macos/README.md` 的 "Keys"。没有读过、也没有移植 `client/spectre`、spectre-qt 的代码（GPL-3.0），按键映射表是照 USB HID Usage Tables（Keyboard/Keypad page 0x07）和 Apple 公开的键码常量（Carbon 的 `kVK_*`）写的。

## 分层

```
App/Shared/PlaybackModel           会话建立后创建 SessionInput，结束时先释放按键再断开
  └ SpectreKit/Input
      ├ MacSessionView (macOS)     MTKView 子类：本地事件监听（键盘）
      ├ SessionInput               一个会话的输入状态
      ├ InputSender                记录已按下的键和鼠标键，releaseAll()；丢掉自动重复
      ├ MacKeyCodes / HIDUsage     kVK → HID usage
      └ LocalShortcut              留在本地的快捷键
          └ GDPKit.GDPSession      sendKey / sendPointer*（任意线程，切到会话队列）
```

## 键盘

**按物理位置**（§8.2）：macOS 用 `NSEvent.keyCode`（`kVK_*`，物理位置）查表得到 HID usage，host 按自己的键盘布局解释。字符、输入法都不参与。

- **修饰键**：`flagsChanged` 的 keyCode 区分左右键（`kVK_Shift`/`kVK_RightShift` 等），按下还是松开看 `modifierFlags` 里与设备相关的位（IOKit `NX_DEVICE*KEYMASK`）。Caps Lock 每次切换只报一次 `flagsChanged`，所以每次都发一次按下加松开。fn 键没有 0x07 页的 usage，不转发；fn 和方向键组合时，macOS 已经把 keyCode 换成了 Home/End/PageUp/PageDown，可以照常转发。
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
