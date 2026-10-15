# 全屏时隐藏工具栏（macOS）

macOS 全屏时，系统默认一直显示窗口的工具栏，画面从工具栏下面开始，远端桌面比屏幕矮一截（1920×1080 的屏幕上是 1920×1028）。现在像 VMware Fusion 那样，全屏时工具栏和菜单栏一起收起，画面铺满整个屏幕；把指针推到屏幕顶边，两者滑下来盖在画面上，移开后再收起。

- 开关在菜单栏的 **View → Hide Toolbar in Full Screen**，默认开，记在 `UserDefaults` 的 `hidesToolbarInFullScreen` 里。关掉后恢复系统的默认行为（全屏时工具栏一直显示）。
- 只有 macOS 有。iPad/iPhone 上会话本来就铺满屏幕，按钮在画面左上角。

## 实现

在 `App/Shared/SpectreApp.swift`。

- **`windowToolbarFullScreenVisibility(.onHover)`**（SwiftUI，macOS 15 起）：这是一个 View 修饰符，不是 Scene 修饰符，挂在 `WindowGroup` 里的 `ContentView` 上。关掉选项时传 `.visible`。
- **工具栏唤出时画面不缩**：工具栏是盖在画面上面的，会话视图的大小始终是整个屏幕（1920×1080），所以唤出、收起都不会让远端改分辨率（见 [resolution.md](resolution.md)）。捕获鼠标时本地指针锁住，碰不到顶边，工具栏不会被误唤出。
- **自动退出再进入一次全屏**（`AppDelegate.reenterFullScreen()`）：SwiftUI 只在窗口进入全屏的那一刻读这个修饰符，所以下面两种情况要让窗口退出全屏，等 `didExitFullScreenNotification` 之后再进入，有一段大约 1 秒的动画：
  - 全屏时在 View 菜单里切换了这个选项；
  - 启动时窗口被恢复成全屏（App 崩溃或被强制结束之后，或者登录时系统重新打开窗口）。恢复发生在 `applicationDidFinishLaunching` 之前，这时 SwiftUI 还没把设置应用上，工具栏仍然显示。正常退出（Cmd+Q、关窗口）时系统默认会关闭窗口（全局的 `NSQuitAlwaysKeepsWindows` 没设），下次启动不会恢复全屏，也就不会有这段动画。
  - 不在全屏时切换选项什么都不做，下次进入全屏时生效。

## 踩到的坑

- **AppKit 的 `.autoHideToolbar` 用不上**：本来想不用 SwiftUI 的修饰符，在进入全屏、切换选项时自己设置 `NSApp.presentationOptions`，加上或去掉 `.autoHideToolbar`。实测在全屏中设成 3077（`.fullScreen | .autoHideToolbar | .autoHideMenuBar | .autoHideDock`）后，读回来仍是 1029，没有 `.autoHideToolbar`，也没有任何报错。窗口全屏时的 presentation options 由窗口的 delegate（`window(_:willUseFullScreenPresentationOptions:)`）决定，而这个 delegate 归 SwiftUI 所有。另外 App 不在前台时 `NSApp.presentationOptions` 读出来是 0，`currentSystemPresentationOptions` 在全屏中也只有 1024（`.fullScreen`）。
- **SwiftUI 修饰符不随设置刷新**：在全屏中把 `.onHover` 改成 `.visible`（或者反过来），工具栏保持原样，要等下一次进入全屏才变。所以才有上面的“退出再进入”。

- **全屏时捕获鼠标，指针动不了**（0.1.5 里的问题）：要在全屏时点 Capture Mouse，得先把指针推到顶边唤出工具栏，这时最后一次绝对移动把远端指针放在了画面最顶上（y≈0.001）。捕获时本地指针原来是移到远端指针的位置再锁住，结果锁在了 y=1079（菜单栏高 30 点）的菜单栏里，鼠标的移动全给了菜单栏，送不到会话视图。现在锁在会话视图的中央（见 [input.md](input.md)）。
  - 锁到中央之后，菜单栏和工具栏仍然不收起：系统要看到指针离开顶部才会收起它们，而锁住的指针一动不动。它们会一直盖在画面顶部，直到捕获结束。所以全屏时捕获期间用 `NSMenu.setMenuBarVisible(false)` 收起菜单栏，工具栏跟着一起收起；捕获结束时 `setMenuBarVisible(true)`，回到自动隐藏，推到顶边还能唤出。捕获期间唤不出工具栏，用 Ctrl+Cmd+G 结束捕获。
  - computer-use 合成的鼠标移动会直接移动指针，复现不了“锁在菜单栏里收不到移动”这一步；这一点是从锁定位置（日志里的 `NSEvent.mouseLocation`）和用户的报告推断的，没有用真实鼠标在修复前后对比过。

## 验证

macOS 27，Debug 版，`--source loopback`，1920×1080 点的 DELL U2725QE。为了不和已经在跑的正式版（同一个 bundle id）混在一起，测试版用 `PRODUCT_BUNDLE_IDENTIFIER=org.ghost.spectre.apple.fsdev` 构建。会话视图的尺寸用临时加在 `sessionViewChanged` 里的日志看。

| 操作 | 会话视图 | 结果 |
|---|---|---|
| 选项打开（默认），从窗口进入全屏 | 1920×1080 | 工具栏、菜单栏都收起，画面铺满 |
| 指针推到顶边，再移开 | 不变 | 菜单栏和工具栏盖在画面上，移开后收起 |
| 选项关掉后进入全屏 | 1920×1028 | 工具栏一直显示，和以前一样 |
| 全屏中关掉选项 | 1920×1080 → 1280×748 → 1920×1028 | 自动退出再进入，工具栏显示 |
| 全屏中打开选项 | 1920×1028 → 1280×748 → 1920×1080 | 自动退出再进入，工具栏收起 |
| 窗口模式下切换选项 | 1280×748 | 窗口不动 |
| 全屏时强制结束，再启动（恢复成全屏） | 1920×1028 → 1280×748 → 1920×1080 | 自动退出再进入，工具栏收起 |

**全屏时捕获鼠标**（同样的环境，在唤出的工具栏上点 Capture Mouse）：修复前本地指针锁在 (1451, 1079)，工具栏和菜单栏一直显示；修复后锁在 (960, 540)，菜单栏和工具栏立即收起，画面铺满，Metal 画的远端光标在顶边原来的位置；在画面里点一下再按 Ctrl+Cmd+G 结束捕获后，推到顶边又能唤出菜单栏和工具栏，移开后收起。窗口模式下捕获时菜单栏照常显示，结束捕获正常。

**还没验证的**：连接真实 host 时远端分辨率的变化（按上面的视图尺寸，全屏时应该请求 1920×1080，而不是以前的 1920×1028）；带刘海的 MacBook 内置屏幕；全屏捕获时用真实鼠标移动远端指针（computer-use 做不到，见上面）。
