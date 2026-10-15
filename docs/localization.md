# 界面语言（本地化）

App 的界面有 5 种语言：英文、西班牙语、简体中文、繁体中文、日语，跟随系统的语言设置（iOS 上也可以在“设置 → Spectre → 语言”里单独选）。系统语言不在其中时显示英文。

## 文件

```
App/Shared/Localizable.xcstrings          App 的界面文字（登录页、工具栏、提示、会话结束的原因）
App/Shared/InfoPlist.xcstrings            Info.plist 里的文字：麦克风权限说明
Packages/SpectreKit/Sources/SpectreKit/Localizable.xcstrings
                                          SpectreKit 的文字：登录步骤、§12 错误码的说明、软键盘附加键条
scripts/sync-strings.sh                   把代码里的文字同步进 catalog
Packages/SpectreKit/Tests/SpectreKitTests/LocalizationTests.swift
                                          检查每种语言都有每一条译文
```

- 都是 Xcode 的 String Catalog（JSON）。源语言是英文：键就是英文原文，工程的开发语言（`project.yml` 的 `developmentLanguage`）和 SpectreKit 的 `defaultLocalization` 都是 `en`，所以缺少的语言回退到英文。
- 构建时 Xcode 把 catalog 编译成各语言的 `.lproj`（App 里，以及 `SpectreKit_SpectreKit.bundle` 里），xcodegen 从 catalog 里认出有哪些语言。

## 代码里怎么写

- **SwiftUI 视图**：`Text("…")`、`Button("…")`、`Label("…", systemImage:)`、`.help("…")` 里的字面量本来就是 `LocalizedStringKey`，会自动查表，插值变成 `%@`、`%lld`。
- **不在视图里的文字**（模型里生成、之后才显示的）：App 里用 `String(localized: "…")`，SpectreKit 里用 `String(localized: "…", bundle: .module)`，否则会到 App 的表里去找。
- **不翻译的**用 `Text(verbatim:)` 或者传 `String` 变量，它们不会进 catalog：
  - 服务器自己发来的文字：lobby 的提问（“Password:”）、拒绝原因、桌面类型的名字。
  - libgdp 和传输层给出的原因（“Timer expired”），附在翻译过的句子后面原样显示。
  - 统计浮层、命令行参数的错误和 macOS 上测试源的开发者选项（Loopback、Codec、Pacing），跟日志一致，方便对照。
  - App 名 Spectre、`用户名 @ 服务器`、指纹的 `SHA-256`，以及键帽上的字（Esc、Tab、Ctrl、Shift、Alt、Super、F1–F12）。
- **复数**：带数量的句子写成一句（`"\(count) characters can't be typed…"`），在 catalog 里给英文和西班牙语加 `one`/`other` 变体；中文和日语没有复数变化，一条就够。

## 新增或修改文字

1. 改代码。
2. 运行 `scripts/sync-strings.sh`：给 macOS 和 iOS 模拟器各编译一次（编译器会列出它找到的文字，`SWIFT_EMIT_LOC_STRINGS`），新文字以“未翻译”进入 catalog，代码里不再用的标成 stale。
3. 在 Xcode 里打开 catalog，或者直接改 JSON，补齐 4 种语言，删掉 stale 的条目。
4. 跑 SpectreKitTests：`LocalizationTests` 检查
   - 三个 catalog 的源语言都是英文；
   - 没有 stale 条目；
   - 每条文字在 `zh-Hans`、`zh-Hant`、`ja`、`es` 里都有译文，状态是 translated（复数的每个变体都算）；
   - 译文里的占位符和原文一致（`%@`、`%lld` 的个数和种类，允许用 `%1$@` 调换顺序）。

## 术语表

| 英文 | 简体中文 | 繁体中文 | 日语 | 西班牙语 |
|---|---|---|---|---|
| host | 主机 | 主機 | ホスト | host |
| server | 服务器 | 伺服器 | サーバー | servidor |
| session | 会话 | 工作階段 | セッション | sesión |
| remote desktop | 远程桌面 | 遠端桌面 | リモートデスクトップ | escritorio remoto |
| sign in | 登录 | 登入 | サインイン | iniciar sesión |
| Log Out | 注销 | 登出 | ログアウト | Cerrar sesión |
| Disconnect | 断开连接 | 中斷連線 | 切断 | Desconectar |
| take over | 接管 | 接管 | 引き継ぐ | tomar el control |
| certificate | 证书 | 憑證 | 証明書 | certificado |
| fingerprint | 指纹 | 指紋 | フィンガープリント | huella |
| Trust and Continue | 信任并继续 | 信任並繼續 | 信頼して続ける | Confiar y continuar |
| Remember | 记住 | 記住 | 保存する | Recordar |
| Forget | 删除 | 刪除 | 削除 | Olvidar |
| Capture Mouse | 捕获鼠标 | 擷取滑鼠 | マウスをキャプチャ | Capturar ratón |
| Clipboard | 剪贴板 | 剪貼簿 | クリップボード | Portapapeles |
| Gamepads | 手柄 | 遊戲控制器 | コントローラ | Mandos |
| Keyboard | 键盘 | 鍵盤 | キーボード | Teclado |
| Touch / Trackpad | 触摸 / 触控板 | 觸控 / 觸控式軌跡板 | タッチ / トラックパッド | Táctil / Trackpad |
| Microphone | 麦克风 | 麥克風 | マイク | Micrófono |
| Mute / Unmute | 静音 / 取消静音 | 靜音 / 取消靜音 | 消音 / 消音解除 | Silenciar / Activar sonido |
| Statistics | 统计 | 統計 | 統計 | Estadísticas |
| Keychain | 钥匙串 | 鑰匙圈 | キーチェーン | llavero |

- 西班牙语用西班牙的说法（ratón、portátil、vídeo），称呼用 tú，和 Apple 的西班牙语界面一致。
- PC 键名（Home、End、Page Up、Page Down、Delete、Insert、Print Screen、Menu）：中文和日语键盘上印的就是英文，保留英文；西班牙语用西语键盘上的名字（Inicio、Fin、Re Pág、Av Pág、Supr、Insert、Impr Pant、Menú）。
- “Remember”不译成“记住密码”：这个开关出现在所有不回显的提问下面，不一定是密码。

## 测试

- **SpectreKitTests**（新增 5 个，`LocalizationTests`）：见上面第 4 步，外加占位符比较本身的测试。翻译之前先把语言加进检查列表，测试报出简体中文缺 130 条，补齐后通过；其他三种语言同样。

## 实测

**macOS（Release 构建，用 `-AppleLanguages` 指定语言启动）**：

- 简体中文：登录页、首次连接的证书确认、“记住”开关都是中文；demo 里空密码登录，提示“用户名或密码错误。”（来自 SpectreKit 的表，说明包里的译文也生效了）。用 loopback 打开会话，工具栏是“捕获鼠标、剪贴板、手柄、麦克风、静音、统计”，统计浮层和 Loopback / H.264 / On arrival 选择器保持英文。
- 日语：登录页是日语，菜单栏的系统菜单（ファイル、編集、表示、ウインドウ、ヘルプ）也跟着变成日语（App 声明了这些语言，系统菜单才会本地化）。
- 西班牙语：登录页、证书确认（“Primera conexión a …”、“Confiar y continuar”）、“Recordar”开关。
- 法语（不支持）：全部是英文。

**iPad 模拟器（iPad Pro 13-inch (M5)，iOS 27.0），日语，loopback**：工具栏（マウスをキャプチャ、クリップボード、コントローラ、キーボード、トラックパッド、マイク）；附加键条的 ⋯ 菜单是“ファンクションキー”，键名保持英文。

**没有逐条看过的**：每种语言的每一条错误信息（单元测试保证了都有译文、占位符正确）；繁体中文只看了单元测试；长句子在 iPhone 窄屏上的换行。

## 没有做的

- 日文 README：README 现在有英文、简体中文、繁体中文、西班牙语四种，没有日文版。
- 由母语者校对译文：目前的译文是开发时一并写的，欢迎提 issue 修正。
- 从右到左的语言（阿拉伯语、希伯来语）：界面布局没有为它们检查过。
