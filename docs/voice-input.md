# 语音输入（iPad、iPhone）

对着 iPad 说话，说的话在本机转成文字，像提示词面板一样送到主机当前光标处。只有文字离开设备，声音不发给主机。对应 iPad 布局规范的 §3.10（[ipad-layout.md](ipad-layout.md)）。

麦克风只给这个功能用：把麦克风声音转发给主机的功能（[audio.md](audio.md#麦克风)）从 2026-10-16 起停用，SessionHello 不再提供 `microphone` capability，界面上没有开关，代码和测试保留（`PlaybackModel.forwardsMicrophone`）。麦克风权限的说明文字改成了语音输入的用途。

## 文件

```
Packages/SpectreKit/Sources/SpectreKit/Audio/VoiceDictation.swift   转写引擎：音频 → SpeechAnalyzer → 文字
Packages/SpectreKit/Sources/SpectreKit/Input/DictationGesture.swift 麦克风键的手势（纯状态机）、语言选择和角标
Packages/SpectreKit/Tests/SpectreKitTests/DictationTests.swift      手势、语言、用 say 合成语音的端到端测试
App/iOS/VoiceInput.swift                                             VoiceInputModel、麦克风键、浮层、“更多”里的设置
```

## 用法

- **麦克风键**：右下竖条里写提示词键的下面，以及软键盘上方按键栏的第二个键。右上角 9 pt 粗体角标是当前识别语言（中、繁、粤、日、EN、ES……）。
- **按住说话、松手发送**。**轻点**则一直听写，**再点一下**发送。按住时把手指**滑开**（离按下点 60 pt 以上）再松手就**取消**，滑回来则恢复。识别语言没准备好（设备不支持）时键是半透明的，不响应。
- **键帽状态**：准备中（第一次用某种语言时要下载模型）显示小号转圈；录音中是强调色实心、`mic.fill` 跳动；将要取消时是红色实心。
- **浮层**：底部居中、按键栏上方（距底 84 pt），最宽 560，玻璃圆角 22，内边距横 18、纵 14，从底部滑入，不接收触摸。第一行是五根随音量起伏的强调色小竖条和状态（“正在听。松手发送，滑开取消。”“正在听。再点一下麦克风发送。”“松手取消”（红色）“正在准备…”“正在发送…”），下面是识别出的文字：已定稿的主色，还在变化的次要色，最多 6 行。失败时状态行用红字显示原因 4 秒。
- **“更多 › 语音输入”**：语言子菜单（设备支持的全部语言；默认是 iPad 偏好语言里第一个支持的，没有就是美式英语；选过就记住），“说完后按回车”（默认关）。
- **送达**：和提示词面板相同（`PromptModel.deliver`）：放到主机剪贴板再按面板里选的粘贴键（默认 Ctrl+Shift+V），会话没有剪贴板能力时逐字键入。不记进提示词面板的“最近发送”。
- **开始听之前**在远端松开锁定的修饰键；**听写期间主机的声音静音**（`PlaybackModel.isQuietForDictation`，不动用户自己的静音设置），免得扬声器里的声音被一起转成文字。App 进入后台、会话结束时取消正在进行的听写。
- **读屏**：麦克风键是一个按钮，激活一次开始并保持听写，再激活一次发送。

## 实现

- **`SpeechAnalyzer`**（iOS 26 起）：设备端转写，不联网。设备有 `SpeechTranscriber`（较新的模型，`isAvailable`）就用它，否则用 `DictationTranscriber`（键盘听写的模型）。两者都开 `volatileResults`：还在变化的结果不断替换 `volatileText`，定稿的结果追加到 `finalText`。
- **语言模型**：`AssetInventory.status` 不是已安装时，先 `reserve(locale:)`（系统只给每个 App 保留有限几种，满了先释放最早的），再 `assetInstallationRequest(...).downloadAndInstall()`。在这台 Mac 上 `SpeechTranscriber` 支持 45 种语言（含 zh_CN、zh_TW、zh_HK、yue_CN、ja_JP、en_US、es_ES），`DictationTranscriber` 54 种。
- **音频**：`AVAudioEngine` 的输入节点装一个 tap，按设备格式取 4096 帧一块，用 `AVAudioConverter` 转成 `SpeechAnalyzer.bestAvailableAudioFormat` 给的格式，作为 `AnalyzerInput` 送进分析器；同时算 RMS（dBFS，-50…0 映射到 0…1）给音量条。音频会话通过 `AudioSessionCoordinator` 切到 `.playAndRecord`（和以前的麦克风转发同一套设置），结束时恢复。第一次用时请求麦克风权限（`AVAudioApplication.requestRecordPermission`）。
- **结束**：`finish()` 停掉音频、结束输入流，`finalizeAndFinishThroughEndOfInput()` 让最后几个词定稿，等结果流结束后返回全部文字；`cancel()` 直接 `cancelAndFinishNow()`。每次开始和取消都递增一个代号，迟到的结果和准备工作对不上代号就丢掉。
- **测试用的输入**：`start(locale:file:)` 可以用一个音频文件代替麦克风，按 0.1 秒一块、实时速度播放；`startScripted(_:)` 不经过语音识别，把一段文字几个词一组地吐出来，模拟说话。Debug 构建的 App 认两个启动参数：`--dictation-file PATH`、`--dictation-script TEXT`。

## 验证

- **单元测试**（SpectreKit，14 个）：手势（按住发送、轻点保持再点发送、滑开取消和滑回、保持状态下取消、系统收回触摸、读屏）；语言（偏好语言、简繁体推出地区、保存的选择、回退到英语、角标）；脚本模式。
- **端到端**（这台 Mac，真实的 `SpeechAnalyzer`，语音用 `say` 合成）：英语 “Hello from the iPad. Please list the files.” 和中文“你好，请列出当前目录的文件。”都完整转写出来；强制走 `DictationTranscriber` 时英语也能转写（“tests” 听成了 “test”）；取消后文字清空。
- **模拟器**（iPad Pro 11-inch (M5)，iOS 27.0）：模拟器里 `SpeechTranscriber` 不可用，`DictationTranscriber` 列出 54 种语言，但模型装不上（英语“支持但未安装”，下载请求直接返回空；中文显示已安装却拿不到音频格式），所以真正的识别在模拟器里跑不了，界面上显示红字“这种语言无法使用语音识别”。用 `--dictation-script` 验证了界面和送达：轻点开始后浮层显示音量条、状态和文字（定稿主色、变化中次要色），键是强调色；再点一下，主机剪贴板收到完整的一句，随后是 Ctrl+Shift+V；按住约 2.8 秒松手，发出了那段时间里的 12 个字；按住后滑开 110 pt 松手，什么都没发。“更多”菜单里有“语音输入”一组。
- **没有验证**：真机上的实际说话（这台 Mac 的输入音量是 0，模拟器的麦克风只录到静音）、第一次使用时的麦克风权限弹窗、模型下载的耗时、听写时主机声音确实静音、按住时变红的取消状态（只有单元测试和代码）。
