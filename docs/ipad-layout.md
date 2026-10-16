# iPad 界面布局（进行中）

iPad 和 iPhone 的界面按一份 iPad 远程桌面布局规范重做。核心思路：**远程画面是主角，占满整个屏幕；所有控件以 Liquid Glass 材质浮在画面四角，平时收起成圆钮，不挡画面、不抢触摸。** Mac 界面不变，新界面只在 `#if os(iOS)` 里。

## 和规范不同的地方

规范是为“直接连一台 Linux 主机”的 App 写的，Spectre 连的是 ghost，按实际情况做了这些改写：

1. **“主机”是保存的登录**：ghost 先登录服务器（地址、用户名、密码，可能还有一次性验证码等提示），再选设备、选桌面会话。首页的“主机”对应“服务器 + 用户名”；登录 sheet 要走完整个流程（信任指纹、额外提示、选设备、选会话）。ghost 没有 mDNS 广播，所以没有“附近”分组。
2. **平台**：规范只考虑 iPad、最低 iPadOS 26；这里是 macOS + iOS 27 的通用 App。iPhone 沿用 iPad 的布局。
3. **iPad 菜单栏**：iOS 的入口是 UIKit（为了锁定指针，见 [input.md](input.md)），SwiftUI 的 `.commands` 用不了，“会话”菜单改用 `buildMenu(with:)`；同样不配快捷键。
4. **规范里没有的现有功能**：注销、捕获鼠标、游戏手柄、麦克风、静音、Retina 分辨率，都收进左下工具栏的“更多”菜单。
5. **修饰键**：照规范改成“点一下就在远端按下并锁定，打一个键后全部松开”，见 [keyboard.md](keyboard.md#附加键条)。
6. **“匹配 iPad 屏幕”**：规范默认关；Spectre 从 0.1.3 起默认让远端分辨率跟随窗口（[resolution.md](resolution.md)），保持默认开。
7. **软键盘打字**：按美式布局逐字键入，打不出中文；提示词面板优先走“同步剪贴板 + 远端按粘贴键”。

## 分阶段

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 修饰键改为锁定；组合键菜单；强调色；浮动控件的公共组件 | 完成 |
| 2 | 会话界面骨架：强制深色、图层顺序、左下会话工具栏、返回按钮、自动收起、“更多”菜单 | 完成 |
| 3 | 右下 L 形按键栏（UIKit 容器 + 三个 hosting controller，触摸穿透） | 完成 |
| 4 | 软键盘上方 60 pt 的完整按键栏，和悬浮栏共用状态 | |
| 5 | 连接状态卡片、重连胶囊、顶部通知胶囊 | |
| 6 | 提示词面板 | |
| 7 | 画面缩放与平移、填满 / 适合屏幕 | |
| 8 | 首页：侧边栏 + 详情、缩略图、表单、多步登录 sheet、空状态 | |
| 9 | iPad 菜单栏“会话”菜单、玻璃样式的性能面板 | |
| 以后 | 区域提醒、语音输入（语音转文字，和麦克风转发是两回事） | |

## 公共组件（阶段 1）

`App/iOS/FloatingControls.swift`：

- **`FloatingKeyBar`**：所有浮动控件共用的尺寸和动画。圆钮 52 pt，距安全区边缘 12 pt，圆钮和条之间 8 pt；展开收起都是 `.smooth(duration: 0.35)`；键帽至少 40 × 36 pt、左右内边距 10；条内边距 6、键间距 2；分隔线 22 pt、两侧各 4；大卡片圆角 28；软键盘辅助栏高 60；动态字体封顶 `xxLarge`。
- **`FloatingToggle`**：四角的玻璃圆钮。图标旋转 90° 淡出，`xmark` 从 -90° 转入；平时淡白色 tint，需要提醒时（收起时有锁定的修饰键）传强调色。
- **`CapsuleReveal`**（`.capsuleReveal(_:from:)`）：条始终占着布局，用胶囊形 mask 从靠圆钮的一端伸出、缩回成半个条宽的小圆点，同时淡出；收起时不接收触摸、读屏跳过。不用 `if` 插入移除，免得宿主尺寸变化让圆钮跳动。
- **`KeyCap` / `KeyCapStyle`**：键帽平时透明透出玻璃，按下是 `primary` 18% 的胶囊，“点亮”是强调色实心、白字，并带 `.isSelected`；长按显示放大版（`accessibilityShowsLargeContentViewer`）。按住才算按下的键（方向键）用拖动手势加 `.keyCap(isPressed:)`，松手才触发的键用 `KeyCapStyle`。
- **`KeyBarSeparator`**：组间的细分隔线，横条里竖着、竖条里横着。

**强调色**：`App/iOS/Assets.xcassets` 的 `AccentColor`，浅色 `#4F6BFF`、深色 `#7493FF`（规范的默认蓝紫色；图标是六色光谱，没有单一主色可取）。`project.yml` 只对 iOS SDK 设 `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`，Mac 仍跟随系统强调色。所有 `.tint` 默认跟随它，现有的登录页也随之变色。

## 会话骨架与左下工具栏（阶段 2）

`App/iOS/SessionControls.swift`，由 `SessionView`（`App/Shared/ContentView.swift`）在 iOS 上叠在画面上；Mac 的窗口工具栏照旧。

- **外观**：会话界面强制深色（`.environment(\.colorScheme, .dark)`），隐藏状态栏和主屏幕指示条（`.statusBarHidden()`、`.persistentSystemOverlays(.hidden)`）。原来横在顶部、可以横向滚动的一排按钮去掉了，画面上方不再被挡。
- **图层**（自下而上）：黑底、画面、重连卡片、“打不出来”的提示、左下工具栏、左上的返回按钮和统计浮层。后面几个阶段会把状态卡片、顶部通知、提示词面板等插到对应的层里。
- **左下工具栏**：`FloatingToggle`（`line.3.horizontal` ⇄ `xmark`）加一枚玻璃胶囊，用 `capsuleReveal(_:from: .leading)` 从圆钮伸出。胶囊里从左到右是：
  1. **更多**（`ellipsis`）；
  2. **粘贴到主机**：系统 `PasteButton`，读 iPad 剪贴板不弹“允许粘贴”。剪贴板同步打开时才显示；原来勾选“自动发送拷贝”后会隐藏它，现在照规范一直显示；
  3. **键盘**：弹出时点亮，图标变成 `keyboard.chevron.compact.down`，无障碍标签在“显示键盘 / 隐藏键盘”之间切换。
  区域提醒的铃铛等以后做到那个功能时再加。
- **“更多”菜单**：分组为显示（匹配窗口大小、性能信息；Retina 分辨率单独一组，带原来的说明）、剪贴板（共享剪贴板；自动发送拷贝，带“iOS 会先询问”的说明）、输入（输入方式子菜单：触控板 / 触摸，图标随当前模式变化；捕获鼠标；游戏手柄）、声音（静音、麦克风），最后是“注销…”（destructive，确认后才注销）。规范里没有的现有功能都收在这里。菜单从底部按钮向上弹出，iOS 会把第一组放在离手指最近的位置，所以“显示”在最下面。
- **返回按钮**：工具栏展开时淡入，左上角（左 16、上 12），`.glass` 样式、`.large`，标签是会话标题（`用户名@服务器`），点一下断开、回到登录页（远程会话继续运行）。只有远程会话有；本机测试源（loopback）没有可以返回的登录页，所以不显示。统计浮层排在它下面。
- **自动收起**（`SessionChrome`）：第一次进入 `.playing` 时展开工具栏，4 秒后自动收起；在此之前手指一碰画面就立即收起（`SessionInput.onPictureTouch`，由 `IOSSessionView.touchesBegan` 调用，手指、触控板点击都算）。只要碰过工具栏上的任何控件（圆钮、菜单、按钮；用整条胶囊上的同时手势捕获，菜单这类 UIKit 控件也算），本次会话就不再自动收起，只能用圆钮收起。重连后的 `.playing` 不会再次展开。

### 验证

iPad Pro 11-inch (M5) 模拟器，iOS 27.0：

- loopback：编码测试流期间只有收起的圆钮；开始播放后工具栏展开，约 4 秒后收起。点圆钮展开，“更多”菜单的各组都在，“输入方式”子菜单切到“触摸”后偏好里的 `touchMode` 变成 `direct`。点过工具栏以后再点画面，工具栏不收起，点击照常发到 host（`BTN_LEFT` 按下、松开）。
- 独立测试主机（草稿目录里的小工具，跑 `LoopbackHost`，App 用 `--connect` 连接，算远程会话）：左上角出现返回按钮“‹ 127.0.0.1:端口”；重新连接后约 1.5 秒点一下画面，工具栏和返回按钮立即一起收起。
- 菜单、键帽都是深色玻璃，模拟器本身是浅色外观。
- Mac 只做了编译检查（改动只是把 iOS 不再用的代码包进 `#if os(macOS)`），没有重新运行。

## 右下按键栏（阶段 3）

`App/iOS/KeyBar.swift`（模型和 SwiftUI 视图）、`App/iOS/RemoteScreen.swift`（UIKit 容器）。

- **结构**：iOS 的画面不再用 SpectreKit 的 `VideoView`，改用 `RemoteScreen`（`UIViewControllerRepresentable`）。它的 `RemoteScreenController` 里铺满一个 `IOSSessionView`，上面是三个 `UIHostingController`：圆钮、竖条、横条，各自 `sizingOptions = .intrinsicContentSize`，只有内容那么大，用 Auto Layout 钉在安全区右下角。L 形之间的空当、收起后的空白，触摸都直接落到画面上。收起时竖条和横条 `isUserInteractionEnabled = false`；隐藏（“更多 › 显示按键栏”关掉，或软键盘弹出）时三者都 `isHidden`。容器用 `withObservationTracking` 跟着 `KeyBarModel` 更新这些属性和横条的左端约束。
- **圆钮**：和左下完全对称（`FloatingToggle`，图标 `keyboard`）。收起时如果有锁定的修饰键，玻璃改用强调色 tint。每次进入会话都从收起开始。
- **竖条**（`FloatingKeyColumn`）：圆钮正上方，和圆钮同宽（52 pt），`capsuleReveal(from: .bottom)` 从下往上展开；顶端不越过安全区顶部（约束 + 放不下时竖向滚动）。目前是 ↑ ← → ↓；写提示词、语音输入在对应阶段再加。
- **横条**（`FloatingKeyRow`）：圆钮左侧、中线对齐，`capsuleReveal(from: .trailing)` 从右往左展开。三组：Esc、⌃C、Tab、Shift+Tab、退格、回车 ┃ Ctrl、Alt、Super、Shift ┃ “更多组合键”菜单（`KeyCombo.menu`，标题加说明）。`ViewThatFits` 放得下就按内容宽度显示，放不下改为横向 `ScrollView` 并裁成胶囊。左端约束为 ≥ 左下工具栏右端 + 8 pt：`SessionToolbar` 用 `onGeometryChange` 量出圆钮和工具条的右端（全局坐标，和全屏的容器一致），展开时报工具条的、收起时报圆钮的，写进 `KeyBarModel.leadingObstruction`。
- **按键**：Tab、Esc、退格、回车和方向键是“按住”的键（`HeldKey`）：手指停留 0.15 秒后在 host 上按下，直到松手，由 host 自己连发；不到 0.15 秒就松手算一次轻点。⌃C、Shift+Tab 和菜单里的组合键松手时发送。修饰键点一下锁定、再点一下松开（见 [keyboard.md](keyboard.md#附加键条)），锁定时键帽是强调色实心、带 `.isSelected`。
- **按住的键为什么是 Button**：第一版用 `DragGesture(minimumDistance: 0)`，结果在 iPhone 窄屏上，横条变成滚动视图后，从这些键上开始的滑动既不能滚动，还会发出一次 Tab。改成 `.simultaneousGesture` 后不再误发，但仍然滚不动：SwiftUI 的拖动手势会挡住外层 ScrollView 的平移。最后改成 `Button`，再用一个 `ButtonStyle` 上报 `isPressed` 的变化：滚动视图可以把触摸收回去（按钮的按下状态取消，action 不触发），所以滑动照常滚动、什么都不发；按下 0.15 秒没被取消才开始按住。代价是按住的开始晚了 0.15 秒（加上滚动视图本身的触摸延迟）。

### 验证

iPad Pro 11-inch (M5) 和 iPhone 17 模拟器，iOS 27.0，loopback：

- 左右圆钮对称；展开后竖条在圆钮正上方、横条在左侧与圆钮中线对齐；两侧同时展开时 iPad 竖屏放得下。
- 点 Ctrl：host 立即收到 Ctrl 按下；再长按 →：→ 按下，约 2 秒后（按住 3 秒）松开，接着 Ctrl 松开。轻点 → 只有一次按下和松开。
- 菜单里点 Super+Tab：host 收到 `Super↓ Tab↓↑ Super↑`。
- 锁定 Super 后收起，右下圆钮变成强调色；再展开点 Super 松开。
- 触摸穿透：展开时点 L 形中间的空当、收起后点原来竖条和横条的位置，都作为点击送到 host，没有发出按键。
- 打开软键盘：悬浮按键栏隐藏，键盘上方仍是原来的附加键条（第 4 阶段替换）。
- iPhone 17 竖屏：两侧都展开时横条收窄到左侧工具栏右边 8 pt 处，变成横向滚动；从 Esc 上开始的滑动可以滚到 Alt、Super、Shift，host 没有收到任何按键。
- 没有在真机上试，没有试台前调度的窄窗口（模拟器里不方便调窗口大小），也没有试最大号的动态字体。
