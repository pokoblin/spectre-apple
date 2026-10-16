# 会话音频

照 `third_party/ghost/docs/spec/gdp-spec.md` §6.8、§10、§11 自行实现。上游的行为只参考了设计文档（`docs/design/audio-cursor-gamepad.md`、`docs/design/spectre-client.md` 的 Audio 一节），没有参考 `client/spectre/src/audio/` 的代码（GPL-3.0）。

## 规范要点

- **不用声明**：音频不是 capability（§6.7 的表里没有），`SessionHello` 也没有音频字段（§6.8："只有一种格式，没什么可协商的"）。只要 host 能采集音频，`SessionAccept.audio` 里就会带上格式，并开始发送音频 datagram；没有采集就不带 `audio`，也不发包。客户端不支持这个格式时，**必须照常运行会话，只是没有声音**，不能让会话失败。所以 SessionHello 不用改。
- **格式**：这个版本的 host 发 `{48000 Hz, 2 声道, 10 ms, "opus"}`。wraith 用 libopus 的 `OPUS_APPLICATION_RESTRICTED_LOWDELAY`（只用 CELT），码率每声道 64 kb/s。
- **datagram**（§10）：通道 0x02，6 字节头（`seq` u16 LE、`pts` u32 LE），后面是一个完整的 Opus 包，不分片。`seq` 从会话建立时的 0 开始，每包加一，在 2¹⁶ 处回绕；`pts` 是包里第一个样本的采集时间，用的是 host 的会话时钟（µs，和视频是同一个时钟）。
- **比较**（§11）：`seq` 和 `pts` 只能按差值比较（分别转成 int16、int32），不能直接比大小。
- **静音时 host 不发包**：上游设计文档提到，wraith 在没有声音可发时 `seq` 会停住。所以缓冲区彻底空了之后，要在下一个到达的包上重新对齐，不能一直往前做丢包补偿，否则之后每个真正的包看起来都是迟到的。

## Opus 解码：用系统自带的

`AVAudioConverter` + `kAudioFormatOpus`（AudioToolbox），不引入 libopus。实验（2026-10-14，Apple M4 Pro，macOS 27.0.1 和 iPad Pro 13-inch (M5) 模拟器 iOS 27.0）：

| 项目 | 结果 |
|---|---|
| 48 kHz 立体声、10 ms（480 帧）一次解一包 | macOS 和 iOS 模拟器都可以 |
| 系统编码器编出的包 | TOC 0xF4：CELT、全频带、10 ms、立体声、一帧，和 wraith 发的一样 |
| libopus 编的包（ffmpeg 的 libopus，`-application lowdelay -frame_duration 10 -b:a 128k`，和 wraith 的参数一样） | 能解。左右声道分别解出 439 / 660 Hz（原信号 440 / 660 Hz），幅度正确 |
| 丢包补偿（PLC） | 送一个 0 字节的包，解出 480 帧，是真正的 PLC：和没丢包时相比，第 1 个丢失块 SNR 32 dB，接下来 14 dB、6.5 dB 逐渐衰减，之后的真包恢复平滑（第 8 块已经回到 51 dB）。只有 TOC 字节的包也一样被当作丢包 |
| 解码耗时 | 每包约 27 µs（macOS），约 51 µs（模拟器） |
| **帧数不固定** | 解码器新建或 `reset()` 之后，第一包只输出 360 帧：去掉了 Opus 的 pre-skip（120 个样本）。所以后面用 PCM 环形缓冲区，不假设每包正好 480 帧 |

格式检查（`OpusFormat`）：codec 必须是 `opus`；采样率是 Opus 支持的 8 / 12 / 16 / 24 / 48 kHz 之一；1 或 2 个声道；帧长 5 / 10 / 20 / 40 / 60 ms（`frame_ms` 是整数，2.5 ms 表示不了）。不满足就当作没有音频（§6.8）。

## 抖动缓冲（`AudioJitterBuffer`）

纯逻辑，不依赖 AVFoundation，自身不加锁（由持有者加锁）。

- **起播**：攒够 `targetPackets`（默认 6 包，也就是 60 ms，和上游一样）才开始播放，以缓冲区里最小的 `seq` 作为期望序号。起播时队列里如果多于 6 包（没人取包时积压下来的，比如引擎还在启动、App 在后台），只留最新的 6 包，否则多出来的延迟会一直保留下去：漂移修正的参考值取的是起播后第一个窗口的平均深度。短促的声音后面紧跟着静音时，host 不再发包，攒不够 6 包；所以最早的包等满 60 ms 也会开始播放。
- **取下一包**（每个包的时长取一次）：期望的包在，就交出去解码；不在、但已经有更新的包，就判定丢失，交出一个"补偿"槽（Opus PLC）；什么都没有就返回 nil，**不往前补**。连续丢多个包时逐个补偿，这样播放时间线始终和 host 对齐，延迟不变。
- **欠载**：只有输出真的断了（渲染时环形缓冲区空了）才调用 `underrun()`：停止播放，回到缓冲状态，在之后到达的包上重新对齐，中间的空档不做补偿。
- **迟到和重复**：比期望序号早的包（它的位置已经播过或补偿过了）、重复的包，直接丢掉并计数。
- **重新同步**：新包领先期望序号 50 包（500 ms）以上，或者缓冲期间和已有的包相差 50 包以上，就清空缓冲重新开始。
- **溢出**：积压超过 `maxPackets`（12 包）时，丢掉最旧的包，降回 6 包。缓冲期间也这样做，否则没人取包时队列会越积越长，跨度超过 50 包时会被误判成跳变。起播和溢出时丢掉的包记在 `trimmed` 里，和漂移修正的 `dropped` 分开。
- **时钟漂移**：两端时钟有几十 ppm 的差，持续播放时缓冲深度会慢慢漂。每 200 次取包（2 秒）算一次平均深度，和起播后第一个窗口的平均值比较，差到 1.5 包就丢掉一包（太满）或者插入一个补偿槽（太空）。100 ppm 的漂移大约每几分钟修正一次，每次是一个 10 ms 的小跳变。

## 播放

```
GDPSession（网络队列）──packet──▶ AudioJitterBuffer（Mutex）
                                       │ 按 seq 取：包 / 补偿 / 没有
解码线程（userInteractive，信号量唤醒）──▶ OpusDecoder ──▶ AudioRing（SPSC 无锁）
                                                                  │
Core Audio 实时线程：AVAudioSourceNode 只做拷贝，不够的部分填静音 ◀──┘
  → mainMixerNode（静音 = 音量 0）→ 输出设备
```

代码：`Packages/SpectreKit/Sources/SpectreKit/Audio/`。`AudioPipeline` 是不涉及音频设备的那部分（抖动缓冲 + 解码 + 环形缓冲区），`SessionAudioPlayer` 加上 `AVAudioEngine`、解码线程和系统通知。

### 解码到播放的交接（`AudioRing`、`AudioPipeline`）

渲染回调跑在 Core Audio 的实时线程上，那里不能加锁、不能分配内存、不能调 ObjC，而 `AVAudioConverter` 这几样都占。所以解码放在另一个线程上，解出的 PCM（交错 Float32）写进一个单生产者、单消费者的无锁环形缓冲区（`Synchronization.Atomic` 记录读写位置），渲染回调只做拷贝和去交错。单声道的源会复制到所有输出声道。

- **解码线程**：每次渲染后被信号量唤醒一次（`DispatchSemaphore.signal` 可以在实时线程里调用），每到一个包也唤醒一次，另外最多等 5 ms 就自己醒来。每次醒来都把环形缓冲区补到"预读量"：至少 2 包（20 ms），而且不少于见过的最大一次渲染请求加一包。iOS 锁屏时一次渲染 4096 帧（85 ms），所以环形缓冲区的容量是 8192 帧。
- **欠载的判断**：渲染时环形缓冲区不够，不够的部分填静音，并设置一个原子标志。解码线程下次醒来时，如果抖动缓冲里**已经没有包**，才算真正的欠载（调用 `underrun()`，重新缓冲）；还有包的话，只是解码线程落后了（比如突然来了一个大的渲染请求），补上就行，不重新缓冲。
- **清空**（中断、换设备）：抖动缓冲和解码器在解码线程这边清空；环形缓冲区的读位置只能由读的一方改，所以只设置一个标志，由下一次渲染回调把它清空。

### 引擎和系统事件

- `AVAudioEngine` + `AVAudioSourceNode`（拉模式），节点格式是会话的采样率、标准的非交错 Float32、至少 2 个声道，接到 `mainMixerNode`，由混音器负责转换成设备的格式和采样率。macOS 27 / iOS 27 上 `connect(_:to:format:)` 已经弃用，改用会抛错的 `connectNode(_:to:format:)`。
- **静音**：把混音器的 `outputVolume` 设为 0，其余照常运行，抖动缓冲照常被拉走，所以取消静音时播放的是当前的声音，而不是静音那一刻缓冲下来的。混音器会用大约 30 ms 淡出，不会有爆音。host 不会知道客户端静音了（和上游一样）。
- **macOS**：收到 `AVAudioEngineConfigurationChange`（换了默认输出设备、插拔耳机，引擎会停下）后，清空缓冲、重启引擎。
- **iOS**：`AVAudioSession` 用 `.playback` 加 `.mixWithOthers`：静音开关打开时也有声音，也不会打断其它 App 正在播放的音乐。首选 48 kHz、5 ms 的 IO 缓冲。来电等中断结束后，重新激活音频会话、清空缓冲、重启引擎；media services reset 后重建引擎。App 进入后台时停掉引擎，回到前台时重启。**没有加后台音频模式**：App 一到后台就会被挂起，会话本来也保持不住，后台继续播放是另一个产品决定。
- **输出延迟**：取 `outputNode.presentationLatency`（iOS 上再和 `AVAudioSession` 的 `outputLatency + ioBufferDuration` 取较大值），用来估计声音实际被听到的时刻。

### 播放时刻和 pts

解码线程给每个写进环形缓冲区的包记下"环形缓冲区里的帧号 → pts"（首包被去掉 pre-skip 时 pts 相应往后挪 2.5 ms；补偿出来的包按上一个 pts 加一个包长推算）。渲染回调用一个双字原子量（`Atomic<WordPair>`）记下这次渲染的 host time 和它第一帧的读位置。解码线程据此算出 `(渲染时刻 + 输出延迟) − pts`，按 §11 截成 32 位差值。这个值里含有两端会话时钟零点之间的未知偏差，但视频那边的 `上屏时刻 − pts` 也含有同样的偏差，两者相减就是音画偏差（见下）。

## 接入会话

- `RemoteSession` 收到 Accept 时，如果 `audio` 是能解的格式（见上），就建一个 `SessionAudioPlayer`，在自己的串行队列上启动（不阻塞网络队列），之后的音频包直接从网络队列交给它。格式不支持或者 host 没发 `audio`，就把原因记在 `audioUnavailable` 里，会话照常进行（§6.8）。会话结束时停止播放。
- 静音设置在 `RemoteSession.isAudioMuted` 上，播放器建立之前设置的也算数。
- **loopback**：`LoopbackHost` 在 Accept 里声明 wraith 的格式，每 10 ms 发一个包：每秒一声 0.1 秒的 880 Hz 提示音（音量 0.2，前后各 5 ms 淡入淡出），其余是静音包。这一秒的 100 个包在启动时用系统编码器编好，之后循环发送；`seq` 和 `pts` 像真实 host 那样由测试 host 生成。`--bench` 时不发声音，因为测的是视频。
- 启动时 stdout 会打印 `session: audio opus 48000 Hz, 2 ch, 10 ms`，或者没有音频的原因。

## 界面和统计

- **静音**：会话有音频时，工具栏上有一个 **Mute** / **Unmute** 按钮（`speaker.wave.2` / `speaker.slash`）。静音状态存在 `UserDefaults`（键 `audioMuted`）里，之后的会话和下次启动都沿用。没有做音量滑块，用系统音量就行；也没有加本地快捷键，以免占用一个本来要发给远端的组合键。
- **统计浮层**多了一行（stdout 每秒也打印同样的内容）：

  ```
  audio 57 ms buffered, played 2004, concealed 0, late 0, underruns 0, trimmed 9, drift -0/+0, A/V +35 ms
  ```

  依次是：缓冲的音频（队列里的包加上环形缓冲区里已解码的部分）、播放的包数、补偿的包数、迟到丢弃的包数、欠载次数、起播和溢出时裁掉的包数、漂移修正丢掉 / 插入的包数，以及音画偏差。静音时开头显示 `(muted)`，正在缓冲时显示 `(buffering)`；没有音频时显示原因。
- **音画偏差**：`(音频的播放时刻 − pts) − (视频的上屏时刻 − pts)`。两个时刻都是本机的 host time（`CACurrentMediaTime` 和 `AVAudioTime.seconds(forHostTime:)` 用的是同一个时钟基准），两个 pts 都是 host 的会话时钟，所以两端时钟零点之间的未知偏差正好抵消。正数表示同一时刻采集的声音比画面晚这么多被听到。视频这一侧只在帧真正上屏时更新（`presentedTime > 0`）；窗口被遮挡、帧没有上屏时就不显示这一项。

## 实测（loopback，2026-10-14）

| | macOS 27（M4 Pro，DELL U2725QE，扬声器输出） | iPad Pro 13-inch (M5) 模拟器，iOS 27 |
|---|---|---|
| 缓冲 | 起播后 50–64 ms，约 3 分钟后慢慢降到 33–41 ms | 66–85 ms |
| 补偿、迟到、欠载 | 都是 0（3 分钟、约 18000 包） | 都是 0 |
| 起播时裁掉 | 8–9 包（引擎异步启动期间积压的） | 12 包 |
| 音画偏差 | +33～+46 ms | +81～+86 ms |
| 静音 | 按钮变成 Unmute，浮层显示 `(muted)`，包照常被拉走 | 一样 |

- **漂移**：macOS 上缓冲深度 3 分钟里降了约 12 ms，也就是测试 host 的定时器（主机时钟）和音频设备的时钟差大约 65 ppm，还没到 15 ms 的修正门槛。真实 host 上的漂移要在长时间连续播放（比如放音乐）时测。
- **修正前的问题**：最初的版本里，起播时队列可能已经有 7～12 包，缓冲深度一直在 70–79 ms，音画偏差 +61～+78 ms；统计里还把启动时的溢出裁剪记成了"漂移丢弃"。改成起播时只保留 6 包、单独计 `trimmed` 之后，就是上表的数字。
- **模拟器**：缓冲更深，是因为模拟器的渲染请求更大（预读量至少是最大一次渲染请求加一包）。模拟器的数字不能和真机比较。
- 这一轮验证时窗口大多被其它窗口挡住，视频帧没有上屏，所以 macOS 的音画偏差只在窗口露出来的那段时间里有数。

## 真实 host 实测（ghost，GNOME，内网）

2026-10-15 在内网的真实 ghost host（ghostd + wraith，Ubuntu 26.04，GNOME）上验证：用 macOS 的 Release 版登录，远端桌面的声音能正常播放。这一次没有记录统计浮层的数字（缓冲、补偿、欠载、音画偏差），长时间连续播放时的时钟漂移也还没有测。

## 测试

`swift test --package-path Packages/SpectreKit --filter 'Audio|Opus'`，33 个（参数化的测试按一个算）：

- **抖动缓冲**：攒够才播、短促声音等满目标时间也播、乱序、丢 1 包和连续丢 3 包、迟到和重复、欠载后重新缓冲并重新对齐（`seq` 接着涨和跳了一大段两种情况，都不补偿空档）、`seq` 从 65535 回绕到 0（包括跨回绕点的乱序和迟到）、领先太多时重新同步、溢出裁剪（播放中和缓冲中两种情况：没人取包时只保留最新的，一长串连续的包也不会被当成跳变）、时钟漂移（两个方向各 2000 次取包，host 快或慢 2%：修正 36–40 次，深度始终在起始值 ±3 以内，没有欠载）、清空。
- **Opus**：从 `AudioConfig` 得到格式和不支持的格式；用系统编码器现编一段正弦波（左 440 Hz、右 660 Hz）再解码，检查 TOC、帧数（首包 360，其余 480）、频率和幅度；PLC 输出 480 帧而且接着原来的音调；单声道 24 kHz 20 ms；乱码和超长的包不会崩溃，之后还能正常解码。
- **环形缓冲区**：回绕和去交错、写满和读空、单声道复制到两个输出声道。
- **播放管线**（`AudioPipeline`，模拟每 10 ms 到一个包、每 10 ms 渲染 480 帧）：第 6 个包到达之前全是静音，之后是测试音，频率和幅度都对；丢 1 个包时补偿的那 10 ms 不是静音；host 停发 150 ms 后只算 1 次欠载，接着从 `seq` 1000 恢复，先静音缓冲再出声，中间不补偿也不重新同步；一次 2048 帧的渲染请求不算欠载；播放时刻减 pts 的计算（含 10 ms 输出延迟、首包的 2.5 ms pre-skip、连续 8 包不漂）；清空后重新开始。
- **播放器**（`SessionAudioPlayer`，`AVAudioEngine` 的离线手动渲染模式，不需要声卡，CI 和模拟器上都能跑）：经过引擎和混音器出来的左右声道分别是 440 / 660 Hz，幅度不变；静音后约 30 ms 淡出为全零，但包照常被拉走，取消静音后马上有声音，没有欠载；单声道的源在左右声道上完全一样。
- **端到端**（GDPTestHost → QUIC → GDPSession → RemoteSession → 播放器，离线渲染）：50 个包里有乱序（11 在 10 前面）、丢失（20）、重复（29），逐个到达、逐个渲染：补偿 1 次、重复 1 次、没有迟到、欠载和丢弃，左右声道的频率对；会话建立前设置的静音对之后的播放器有效；三种不支持的格式（aac、44.1 kHz、6 声道）和没有音频时，会话照常进行、没有播放器，原因写清楚；host 关闭会话后引擎停止。
- **GDPKit**：测试 host 自己编号、打 `pts` 的音频（`seq` 0、1、2，`pts` 是会话时钟、递增），以及配置成其它格式时 Accept 里的 `audio`。

# 麦克风

把本机麦克风的声音发给 host（gdp-spec.md §6.7、§6.8、§10.1）。上游的行为只参考了 `docs/design/audio-cursor-gamepad.md` 的 Microphone 一节。

> **2026-10-16 起停用。** 用户决定 App 里先不提供麦克风转发，iPad 和 iPhone 上的麦克风只给语音输入用（[voice-input.md](voice-input.md)）。`PlaybackModel.forwardsMicrophone` 为 false：SessionHello 不再提供 `microphone` capability（`RemoteSession.offersMicrophone`），host 也就不会给桌面接上一个我们的麦克风；工具栏和“更多”菜单里没有麦克风开关。下面的实现和测试都保留，把这个常量改回 true 就恢复。麦克风权限的说明文字也改成了语音输入的用途。

## 规范要点

- **是 capability**（`microphone`），这一点和播放不同：客户端在 SessionHello 里提供，host 支持就在 Accept 的 capability 里回应，同时在 `SessionAccept.microphone` 里给出格式（这个版本是 `{48000 Hz, 1 声道, 10 ms, "opus"}`）。客户端必须严格按这个格式编码，做不到就不开麦克风，会话照常进行。capability 在整个连接期间固定，会话中途不能再加。
- **datagram**：通道 0x03，布局和音频一样（`seq` u16 + `pts` u32 + 一个 Opus 包）。`seq` 从会话建立时的 0 开始；`pts` 用**客户端自己的**会话时钟（收到 Accept 时清零），host 不用它来安排播放。
- **用户要求之前不能打开麦克风，也不能发包**；静音就是停止发包，协议里没有对应的消息。
- host 端缓冲几包，用 PLC 补短的空档，迟到和重复的包丢掉，再把声音作为录音设备交给远端的程序（wraith 的 `gdp-mic`，会被设成会话里默认的录音设备）。

## 编码：系统自带的 Opus 编码器

实验（2026-10-15，macOS 27）：用 `AVAudioConverter` 把 48 kHz 单声道编成 10 ms 的包，写成 Ogg Opus 文件，再用 ffmpeg 的 **libopus 解码器**（wraith 用的也是 libopus）解回来。信号是 300 Hz（幅度 0.3）加 1200 Hz（幅度 0.2）。

| 码率 | 编出来的包 | libopus 解出的幅度（300 / 1200 / 700 Hz） |
|---|---|---|
| 32 kb/s（上游 spectre 的麦克风码率） | 实际 33 kb/s，在 Hybrid（TOC config 14，SILK + CELT）和 CELT（config 30）之间切换 | 0.297 / 0.193 / 0.000 |
| 64 kb/s | 只用 CELT，实际 69 kb/s | 0.300 / 0.200 / 0.000 |

所以麦克风也用系统编码器，不引入 libopus，码率定为 32 kb/s。系统编码器可选的码率是 6、7、8、12、16、20、24、28、32、40、50、60、80、100、120、160、256、512 kb/s。

## 协议层（GDPKit）

- `SessionClient::send_microphone`：会话已建立、`microphone` 生效、Accept 里有格式时才发，否则计入 `microphone_dropped`。`seq` 在收到 Accept 时清零，每发一包加一（停发期间停着不涨）；`pts` 是 `monotonic − 收到 Accept 的时刻`，截成 32 位。超过当前最大 datagram 长度、或者传输层拒绝的包也算丢弃。Swift 端是 `GDPSession.sendMicrophone(opus:)`，在会话队列上执行；`LinkStats` 里有已发和丢弃的包数。
- Accept 里的 `microphone` 只在 `microphone` capability 生效时才交给上层（`Accept.microphone`）；没有协商这个 capability 时，即使 host 发了这个字段也忽略。
- **测试 host**：把 `microphone` 放进它支持的 capability 就会启用；协商成功后在 Accept 里带上 `microphoneFormat`（默认 `{48000, 1, 10, "opus"}`，可以改成别的格式来测试）。它接收通道 0x03 的包，只收已认证的当前 viewer、而且协商了这个 capability 的，其余的计入 `microphoneDropped`（§3.2）。收到的包记下前一分钟（6000 包）的 `seq`、`pts` 和内容，通过 `microphonePackets(from:)` 读取。
- 测试（GDPKit）：`seq` 是 0、1、2，`pts` 从 Accept 开始计时并递增，内容一致，Accept 里的格式正确；客户端没提供或者 host 不支持这个 capability 时，Accept 里没有格式，发出的包在客户端就被丢弃，host 什么也收不到。

## 采集和编码（SpectreKit）

```
AVAudioEngine.inputNode（设备格式）→ AVAudioSinkNode（实时线程，只拷进 AudioRing）
  → 编码线程（信号量唤醒）→ MicrophoneEncoder：AVAudioConverter（重采样、混成单声道）→ 每 480 帧一包 → OpusEncoder（32 kb/s）
  → onPacket
```

- **不用 input tap**：`installTap` 的 `bufferSize` 只是建议值，实际一次交出约 100 ms 的音频，这些全是额外的延迟。`AVAudioSinkNode` 在每个 IO 周期（几毫秒）都会被调用。它运行在实时线程上，所以只做拷贝：`AudioRing.write(from:frames:)` 把非交错的各声道写成交错的帧，不分配内存、不加锁。容量是一秒的设备音频。
- **编码线程**：每次实时回调后被唤醒一次（最多等 20 ms），把环形缓冲区里的音频取出来交给 `MicrophoneEncoder`。转换器按设备格式建立，格式变了就重建；每凑满 480 帧（10 ms）编一包。顺带算出这一包的 RMS 电平（dBFS），给界面上的电平显示用。
- **打开和关闭**：`MicrophoneCapture.start()` 才建引擎、打开设备；`stop()` 停掉引擎、释放设备，系统的麦克风指示灯跟着熄灭。每次打开都是新的引擎，所以换了设备也没关系。macOS 上换了输入设备（`AVAudioEngineConfigurationChange`）就按新设备的格式重开；iOS 上中断结束后、回到前台时也重开。
- **权限**：`AVAudioApplication.requestRecordPermission()`，第一次打开时由系统弹窗询问。Info.plist 里有 `NSMicrophoneUsageDescription`。macOS 开了沙盒和 hardened runtime，所以要加 `com.apple.security.device.audio-input` entitlement。
- **iOS 的音频会话**（`AudioSessionCoordinator`）：播放器和麦克风各自登记自己在用，由协调器决定类别：只有播放时是 `.playback`；麦克风开着时是 `.playAndRecord`，选项是 `.mixWithOthers`、`.defaultToSpeaker`（从扬声器而不是听筒出声）、`.allowBluetoothA2DP`（蓝牙耳机只用来听，录音用设备自己的麦克风；用 HFP 的话可以用耳机上的麦克风，但播放会降到通话音质）。两边都不用时停用音频会话。切换类别会让播放引擎收到配置变更，播放器会重启引擎、重新缓冲。
- **没有做回声消除**：用扬声器播放远端声音时，麦克风会把它录回去，远端的程序会听到自己的声音，所以建议戴耳机。系统的 voice processing 能消除回声，但它要参考同一个引擎的输出，播放也得搬到这个引擎上，播放就会变成偏语音的音质，还会压低其它 App 的声音。以后需要再单独做。

测试（`MicrophoneTests`）：48 kHz 单声道的设备音频按 512、333、1024、97、480 帧这样不均匀地分块送进去，一秒正好得到 100 包，约 32 kb/s，用 `OpusDecoder` 解回来是 440 Hz，电平是 −9.03 dBFS（幅度 0.5 的正弦）；44.1 kHz 立体声的设备音频经过重采样、混成单声道后得到 98–100 包（重采样器会扣下几帧），频率和幅度不变；中途从 48 kHz 换成 16 kHz 也能继续；静音的电平是 −160。环形缓冲区的非交错写入：交错、回绕、写满时只写进能放下的部分。采集设备本身要麦克风权限，不在单元测试里，在 App 里实测。

## 接入会话

- **总是提供 capability**：`RemoteSession.connect` 会在 SessionHello 的 capability 里加上 `microphone`。capability 在整个连接期间固定，不提供的话会话中途就没法再开麦克风。提供了只表示"可以发"，麦克风本身仍然关着，直到用户打开（§10.1）。代价是：wraith 会把 `gdp-mic` 设为远端默认的录音设备，没开麦克风时它就是静音。
- Accept 时：`microphone` 生效、而且格式能编（`OpusFormat` 认得，系统编码器也建得起来），就记下 `microphoneFormat`；否则把原因记在 `microphoneUnavailable` 里（"the host takes no microphone"，或者是什么格式），会话照常进行。
- `setMicrophone(true)`：先请求权限（第一次会弹系统授权框），再在 `RemoteSession` 的音频队列上建立 `MicrophoneCapture` 并启动，每个包直接交给 `GDPSession.sendMicrophone`。`setMicrophone(false)` 停止采集、释放设备。会话结束时自动关闭。每个会话开始时麦克风都是关的，不记住上次的状态。
- loopback 的测试 host 也支持这个 capability，所以不连真实 host 也能看到它收到了什么。

测试（`MicrophoneEndToEndTests`，GDPTestHost → QUIC）：
- 客户端没被要求也会提供 `microphone`。
- 一秒的测试音分两段发出，中间停 100 ms。host 收到 100 包，`seq` 是 0–99，停顿前后连续，`pts` 相差超过 100 ms；在 host 那边用 `OpusDecoder` 解回来是 440 Hz。
- host 不支持这个 capability 时：没有格式，原因写清楚，`setMicrophone(true)` 抛错（在请求权限之前），发出的包在客户端就被丢弃。
- host 给出 44.1 kHz 这种编不了的格式时：没有麦克风，会话照常进行。

## 界面和统计

- 工具栏上的 **Microphone** 开关（`mic.fill` / `mic.slash`），只在 host 接受麦克风时显示。每个会话开始时都是关的。第一次打开时系统会请求权限；被拒绝时弹出提示，告诉用户去"系统设置 → 隐私与安全性 → 麦克风"里打开。
- 统计浮层（和每秒打印到 stdout 的那一行）多了一行：

  ```
  mic on (48000 Hz, 1 ch), 1408 packets, level -23 dBFS, sent 1408, dropped 0 | host received 1408, latest -24 dBFS
  ```

  依次是：设备的格式、编出的包数、最近一包的电平、会话实际发出和丢弃的包数。连的是 App 内的测试 host（loopback）时，还会显示 host 收到的包数，以及它最新收到的那一包解码后的电平，也就是远端会"听到"的声音。没有麦克风时显示原因。

## 实测（loopback，2026-10-15）

| | macOS 27（MacBook Pro，内建麦克风） | iPad Pro 13-inch (M5) 模拟器（用的是 Mac 的麦克风） |
|---|---|---|
| 授权 | 第一次打开时弹出系统授权框，允许后开始采集 | 模拟器里弹出 iOS 的授权框，说明文字就是 `NSMicrophoneUsageDescription` |
| 发送 | 每秒 100 包，host 全部收到（1408 / 1408），没有丢弃 | 一样（1443 / 1443） |
| 关掉 | 发送停止，系统里不再有占用录音设备的 assertion，设备已释放 | 发送停止 |
| 电平 | −160 dBFS：这台 Mac 的输入音量是 0，系统交给所有 App 的麦克风数据都是全零。要看到电平在动，需要在"系统设置 → 声音 → 输入"里把输入音量调上去 | 一样，原因相同 |

- **发现并修正**：iOS 上打开麦克风时，音频会话切到 `.playAndRecord`，模拟器上播放的渲染请求变大，缓冲从约 70 ms 涨到约 105 ms。关掉麦克风后，缓冲原先一直停在约 102 ms（音画偏差 +113 ms），因为预读量取的是"见过的最大一次渲染请求"，只增不减。现在只看最近两个 2 秒窗口里的最大值，关掉麦克风几秒后缓冲回到 60–72 ms，音画偏差回到约 +77 ms。测试 `theLookaheadFollowsRecentRendersOnly` 覆盖这个情况。
- 每次切换音频会话类别，播放引擎都会收到配置变更并重启，`trimmed` 增加约 20 包（一两百毫秒的声音被跳过）。这是开关麦克风的代价；macOS 没有音频会话，不受影响。

## 真实 host 实测（麦克风）

2026-10-15 在内网的真实 ghost host（ghostd + wraith，Ubuntu 26.04，GNOME）上验证：用安装到 `/Applications` 的 macOS Release 版登录，打开工具栏的 Microphone，远端能正常收到本机麦克风的声音。这一次没有记录统计浮层的数字。

