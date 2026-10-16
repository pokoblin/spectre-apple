# Mac 界面布局

2026-10-16 起，Mac 版借用 iPad 的新界面（[ipad-layout.md](ipad-layout.md)）里适合 Mac 的部分：主机首页、玻璃状态卡片、顶部通知、整理过的工具栏和菜单栏的“Session”菜单。Mac 照旧用系统强调色，不用 iPad 的浮动按钮和按键栏（Mac 有实体键盘和鼠标，窗口有工具栏和菜单栏）。

没有搬过来的：提示词面板、区域提醒（用户决定不做）；语音输入和双指缩放（iPad 专用）。

## 文件

```
App/Shared/SpectreApp.swift     两种窗口：首页（Window "home"）和会话（WindowGroup(for: UUID)）；App 菜单的“Trusted Servers…”
App/Shared/HomeView.swift       首页：侧栏的主机 + 详情，iPad 和 Mac 共用
App/Shared/HostForms.swift      添加 / 编辑主机、登录 sheet，共用
App/Shared/SessionStatus.swift  连接状态卡片、重连胶囊、顶部通知，共用
App/Shared/ContentView.swift    SessionView：Mac 的工具栏、“更多”菜单、窗口副标题
App/Shared/SessionMenu.swift    菜单栏的 Session 菜单
App/Shared/AppModel.swift       会话列表：每个会话有自己的 id、登录配方和重放
```

## 首页和会话窗口

- **首页是一个单独的窗口**（`Window`，只有一个，默认 960 × 640，最小 640 × 440），内容和 iPad 首页相同：侧栏分“Recent”“Saved”两组，详情是最后一帧缩略图、主机名、账号、“Connect”和信息卡（上次连接、密码是否存在钥匙串）。侧栏宽 220–250，顶上是“+”（添加服务器）和侧栏开关；“Trusted Servers…”放在 App 菜单里（侧栏顶部放不下两个按钮）。原来的 Mac 登录页去掉了，它的“最近登录”迁移成首页的主机。
- **登录在首页的 sheet 里**，步骤和 iPad 一样（密码 → 信任指纹 → 其他提示 → 选设备 → 选桌面）。Mac 上后面几步的视图自带“Cancel”，sheet 底部就不再放第二个。
- **每个会话一个窗口**（`WindowGroup(for: UUID.self)`，默认 1280 × 800），标题是主机名。登录完成时 `AppModel` 记下会话、调用 `onSessionOpened`，由当前在前面的窗口 `openWindow(value: id)` 打开。可以同时开几个会话，各自断线重连（每个会话有自己的登录配方和重放用的 `LoginFlow`，共用已信任的服务器和钥匙串）。
- **关会话窗口 = 断开**（远端桌面继续运行）。会话自己结束（断开、注销、被顶替、失败后点 Close）时窗口自动关闭，首页窗口回到前面并显示原因。首页关掉也没关系，会话窗口照样能打开下一个、结束时把首页叫回来。最后一个窗口关掉时退出 App。
- **需要重新登录**（重连时遇到要人回答的提示）时，会话窗口关闭，首页打开并弹出登录 sheet，停在那一步。
- 崩溃后系统恢复出来、但已经没有会话的窗口，打开后立即关闭。

## 会话窗口

- **工具栏**：标题前是“‹”（断开，远端会话继续运行）；右边是剪贴板共享、捕获鼠标（Ctrl+Cmd+G）、静音，最后是“更多”（⋯）：分辨率子菜单（Match Window Size、Retina Resolution）、手柄（菜单项下面写着正在转发哪些手柄）、统计信息、“Log Out…”（要确认）。麦克风开关只在麦克风转发打开时出现（现在停用，见 [voice-input.md](voice-input.md)）。命令行的测试源另有 Source、Codec、Pacing 三个选择器。
- **副标题**：画面播放时每秒更新一次连接质量，“12 ms · 60 fps”：传输层的往返时间（不到 1 ms 显示“<1 ms”）和上一秒真正显示出来的帧数。窗口被完全挡住时系统不显示画面，帧数就是 0。连接中、重连中、失败时副标题为空，由卡片说明。
- **状态卡片**（和 iPad 同一套视图，深色玻璃，在画面上）：
  - 连接中：画面压暗 50%，居中卡片“Connecting to “主机”…”+ Cancel。
  - 重连中：画面停在最后一帧、压暗 35%，底部胶囊“Connection lost. Reconnecting (attempt N)…”+ Cancel。
  - 失败（重连用完，或 host 拒绝）：卡片“Couldn't connect to “主机””+ 原因 + Close / Retry。**以前 Mac 上失败直接回到登录页**，现在和 iPad 一样留在窗口里，Retry 从第一次重连重新开始。按钮用大号控件。
  - 压暗层挡住点击，不会点到旧画面上。
- **顶部通知**：剪贴板文字过去或过来时，画面顶部居中一枚玻璃胶囊（“Copied from the host” / “Sent to the host's clipboard”），2 秒后淡出；按 host 美式布局打不出的字符的提示也在这里。
- 统计信息浮层保持原来的黑底白字，位置在左上。

## Session 菜单

菜单栏在 View 和 Window 之间有“Session”菜单，作用于前面那个会话窗口（`focusedSceneValue`）；首页在前面时全部变灰：

- Capture Mouse（勾选状态跟着窗口）
- Send Clipboard to Host：Mac 剪贴板的文字送到 host 的剪贴板（共享关着时，放上去供粘贴）
- Send Keys：iPad 按键栏“更多”里的那些组合键（Super、Super+Tab、Alt+Tab、Ctrl+Alt+T、终端常用的 Ctrl 组合、Home / End / Page Up / Page Down，以及 Other Keys、Function Keys 两个子菜单），每项写成“组合键 — 用途”
- Disconnect、Log Out…（只对真正的远程会话）

**菜单项都不配快捷键**：菜单的快捷键会在远程桌面之前把按键拿走（和 iPad 一样，见 [ipad-layout.md](ipad-layout.md)）。现有的 Ctrl+Cmd+G（捕获鼠标）、Ctrl+Cmd+F（全屏）不变。

## 验证（2026-10-16，这台 Mac）

用本机的测试 lobby（GDPTestLobby，转到进程内的 LoopbackHost）和 `--source loopback`：

- 首页：侧栏、详情、“+”在侧栏顶上；添加主机的 sheet；App 菜单里有 Trusted Servers…。
- 登录 sheet：密码 → 首次连接的指纹确认 → 额外提示（只有一个 Cancel）→ 选 GNOME → 会话在新窗口打开，标题是主机名，首页窗口保留在后面。
- 关闭会话窗口：统计日志停止（已断开），首页显示“Disconnected.”、上次连接时间和缩略图，主机进入 Recent。
- 先关首页再从会话工具栏断开：会话窗口关闭，首页重新打开。
- 新工具栏：“‹”、剪贴板、捕获鼠标、静音、“更多”；副标题“<1 ms · 60 fps”（窗口被别的窗口挡住时是 0 fps）。
- 停掉测试 host：30 秒空闲超时后出现重连胶囊、画面压暗，8 次失败后出现“Couldn't connect to “Lobby Echo””卡片；Retry 重新开始重连，Cancel 关掉会话窗口、回到首页。
- Session 菜单：五项都在，Send Keys 下有两个子菜单；选“Ctrl+L — Clear the screen”，loopback host 收到左 Ctrl（224）+ L（15）的按下和松开。

- iPad 模拟器回归（会话列表改成多会话之后）：首页添加主机 → 登录 sheet（密码、指纹、选桌面）→ 会话全屏打开；用 `kill -STOP` 冻住 App 36 秒再恢复，空闲超时后第 1 次重连按这个会话自己的配方重放登录，画面恢复。

**没有验证**：“更多”菜单展开后的样子（后台的 computer-use 不能打开菜单）；Send Clipboard to Host（会把这台 Mac 剪贴板里的内容写进日志）；菜单里的 Capture Mouse（会抓住正在用的鼠标）；同时开两个会话；需要重新登录时首页弹 sheet；真实 ghost host。
