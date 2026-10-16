# 文件传输（设计）

GDP 1.0 没有文件传输：剪贴板（§7.9）只有 `text/plain`，上游 `docs/design/clipboard.md` 也写明 "no images, file lists"。这份文档是扩展的设计：一个新的 capability 和同名的 stream kind，都叫 `file`，走 §2.2 "Additional streams" 和 §16 第 3 条（新 token）这条路，不改动任何已有字节的含义，不需要新 ALPN。

状态：host 端已经完成，在 [pokoblin/ghost](https://github.com/pokoblin/ghost) fork 的 `feat/file-transfer` 分支上（规范 §7.12、libgdp、wraith，之后向上游提 PR），设计说明见那边的 `docs/design/file-transfer.md`。本仓库的客户端还没有写，会照规范自己实现，不移植上游 GPL 代码。下面以规范 §7.12 为准；和最初设计不同的地方已经改过来了。

## 分两个阶段

| 阶段 | 方向 | 触发 |
|---|---|---|
| 一 | 客户端 → host（上传） | 用户把文件拖进会话窗口，或在工具栏选择文件 |
| 二 | host → 客户端（下载） | 用户在 host 上复制文件（剪贴板里的文件列表），客户端提示下载 |

两个阶段的流**都由客户端打开**：上传是客户端发 offer，下载是客户端发 request。这样 host 永远不需要向客户端开流，客户端的 `initial_max_streams_bidi` 保持 0，§2.2 的默认值不用动。第一阶段只定义 offer；`FileOpen` 做成一个 `oneof`，给第二阶段的 request 留好位置。

## 协商（§6.7）

- 客户端实现了发送就在 `SessionHello.capabilities` 里列出 `file`。
- host 只有在能接收时才在 `SessionAccept` 里回 `file`：找得到可写的下载目录，并且管理员没有关掉这个功能。
- 生效之后，host 用 `MAX_STREAMS` 把客户端可以开的双向流从 2 条（control、input）放开，让客户端能同时开 4 条 `file` 流（`MAX_STREAMS` 是累计值，每关掉一条就再补一条）。超过 4 个文件时，客户端自己排队。
- `file` 没有生效时，客户端不显示任何文件相关的界面。

## 一个文件一条流

```
客户端（发送方）                                        host（接收方）
  │ 打开双向流
  │ ── 帧：StreamOpen{kind: "file", params: FileOpen{offer}} ──▶
  │                                                     校验文件名、空间
  │ ◀── 帧：FileReply{accepted} ───────────────────────── │
  │ ── 原始字节，正好 size 个，然后 FIN ─────────────────▶  写进临时文件
  │                                                     字节数对上 → rename
  │ ◀── 帧：FileReply{saved{name}}，然后 FIN ──────────── │
```

1. 发送方开一条双向流，第一帧（§3.1 的长度前缀帧）是 `StreamOpen`，`kind` 为 `file`，`params` 是序列化后的 `FileOpen`。
2. 接收方在自己的发送方向回一帧 `FileReply`：
   - `accepted`：可以开始发了；
   - `refused{error}`：拒绝，然后 FIN。发送方收到后关掉自己的发送方向（不发数据，直接 FIN）。
3. 发送方收到 `accepted` 之后发**原始字节**，不再分帧，正好 `size` 个，然后 FIN。不分帧是为了省掉每 1 MiB 一个帧头的拆分和拷贝；长度已经在 offer 里，FIN 标出结尾。
4. 接收方读到 FIN 时：
   - 字节数等于 `size` → 把临时文件改名为正式名字，回 `FileReply{saved{name}}`（实际保存时用的名字，重名时会不同），然后 FIN；
   - 少了，或者 FIN 之前就超过了 `size` → 删掉临时文件，回 `FileReply{failed{SIZE_MISMATCH}}`，然后 FIN，超出的数据不再读（`STOP_SENDING`，代码 0）。
5. 写盘出错、空间用完：接收方删掉临时文件，回 `failed{WRITE_FAILED / NO_SPACE}`，然后 FIN，并对发送方的方向发 `STOP_SENDING`（代码 0）。

**取消**：用户在发送方取消，就对这条流的两个方向都 reset（`RESET_STREAM` + `STOP_SENDING`），代码 0。接收方取消也一样。接收方收到 reset 时删掉临时文件。代码 0 表示"取消，不是错误"；`UNSUPPORTED`（15）只用在 §2.2 已经规定的情况，即对方开了一条自己不认识或没有协商过的流。原因都放在 `FileReply` 消息里，不用 reset 代码表达，所以 §12 不需要新的错误码。

**超时**：发送方发出 offer 之后 30 秒内没有收到 `FileReply`，reset 掉这条流，提示失败。正常情况下 host 会立刻回复。

**完整性**：QUIC 本身保证可靠、有序，TLS 保证不被篡改，所以不另外做校验和。

**续传**：第一版不支持。断线时所有传输都算失败，host 删掉临时文件，客户端提供"重试"，从头再发。以后要做续传，可以在 offer 里加一个"我支持续传"的字段、在 `accepted` 里加 `offset`；旧的对端会忽略新字段，所以续传必须由双方都声明支持之后才能用，不能只加一个 `offset` 字段了事。

## 消息

放在 libgdp 的 `session.proto`，和 `StreamOpen` 放在一起，包名 `gdp.session`。

```proto
// StreamOpen.params of a "file" stream (gdp-spec.md §2.2). Always opened by
// the client. A host that gets a case it doesn't know replies
// FileReply{refused{FILE_ERROR_UNSUPPORTED}}.
message FileOpen {
  oneof open {
    FileOffer offer = 1;   // client -> host: here is a file
    // 2 is reserved for FileRequest (host -> client downloads).
  }
}

message FileOffer {
  string name = 1;                // leaf name only, UTF-8 NFC, see the rules below
  uint64 size = 2;                // exactly this many raw bytes follow FileReply.accepted
  int64 modified_unix_ms = 3;     // 0 = unknown; the receiver may set the file's mtime from it
}

// The receiver's frames on a "file" stream, in its own direction.
message FileReply {
  oneof reply {
    FileAccepted accepted = 1;    // send the bytes
    FileError refused = 2;        // offer refused; FIN follows
    FileSaved saved = 3;          // all bytes written and the file is in place; FIN follows
    FileError failed = 4;         // accepted, then failed; FIN follows
  }
}

message FileAccepted {}

message FileSaved {
  string name = 1;                // the name it was saved under (may differ: "name (1).ext")
}

message FileError {
  FileErrorCode code = 1;
}

enum FileErrorCode {
  FILE_ERROR_UNSPECIFIED = 0;
  FILE_ERROR_UNSUPPORTED = 1;     // an unknown FileOpen case
  FILE_ERROR_BAD_NAME = 2;        // the name breaks the rules below
  FILE_ERROR_NO_SPACE = 3;        // not enough free space, checked on accept or hit while writing
  FILE_ERROR_REFUSED = 4;         // the receiver's policy or user said no
  FILE_ERROR_WRITE_FAILED = 5;    // any other I/O error
  FILE_ERROR_SIZE_MISMATCH = 6;   // FIN came before size bytes, or more than size arrived
}
```

接收方对一条 `file` 流上的任何帧，都只认 `FileReply` 这一种 envelope；发送方在收到 `accepted` 之前不能发数据。任何一方收到不合法的帧（解析失败、在不该出现的位置出现），都按 §3.1 用 `MALFORMED_FRAME` 关闭连接，和其他流的规则一致。

## 文件名规则

发送方发出前检查一遍，接收方收到后再检查一遍；不符合就 `refused{BAD_NAME}`：

- 合法的 UTF-8，不为空，最多 255 字节（ext4 的 `NAME_MAX`）；
- 不含 `/`、`\`、`\0`，不含控制字符（U+0000–U+001F、U+007F）；
- 不是 `.` 或 `..`。

发送方在发出前把名字规范化成 NFC。macOS 有时给出 NFD 的名字，Linux 把名字当作字节，同一个"é"会变成两个看起来一样的文件名。

只传最后一段文件名，不传路径。第一版**不传文件夹**，包括 macOS 的包（`.app`、`.key` 这类实际上是文件夹的文件），选中时在客户端直接提示不支持。

## host 端怎么保存

- 目录：`XDG_DOWNLOAD_DIR`（从 `~/.config/user-dirs.dirs` 读），没有就用 `~/Downloads`；目录不存在或不可写，就不提供 `file`。
- 先在目标目录里用 `mkostemp` 建一个隐藏的临时文件 `.ghost-receiving-XXXXXX`，写完用 `renameat2(RENAME_NOREPLACE)` 改成正式名字，所以永远不会覆盖已有文件，也不会顺着符号链接写到别处（文件系统不支持 `RENAME_NOREPLACE` 时退回硬链接，再不行才是先检查再 rename）。最初设计的 `name.part` 没有采用：255 字节的名字加上 `.part` 会超过 `NAME_MAX`。权限按 umask（`0666 & ~umask`）。
- 重名：依次试 `name (1).ext`、`name (2).ext`……，数字加在最后一个扩展名前面（`archive.tar (1).gz`）；没有扩展名、或者只有开头一个点（`.bashrc`）时加在最后；超长时按整个字符截短。最终的名字写在 `FileSaved.name` 里告诉客户端。
- 写盘在单独的线程里做，凑够 256 KiB 写一次；写完才 `consume()` 归还这条流的接收额度。wraith 的事件循环同时负责编码画面，慢磁盘不能卡住它。
- 接受前用 `statvfs` 检查剩余空间至少有 `size` 再加 64 MiB，不够就 `refused{NO_SPACE}`。
- 有 `modified_unix_ms` 就用 `futimens` 设置 mtime。
- 通知：所有传输都结束、并且 1 秒内没有新的传输，就发一条桌面通知（`org.freedesktop.Notifications`，不等回复），例如 "Received 3 files / Saved in ~/Downloads"。拖进 10 个文件只弹一次。通知不能点击打开目录（要监听 `ActionInvoked` 信号，第一版没做）。
- `wraith.toml` 的 `[files]`：`receive = false` 关掉接收，关掉后不提供 `file`；`directory` 换保存位置。
- 客户端违反协议（开头那一帧过大或解析失败、在 `accepted` 之前就发数据）：关闭整个连接，代码 `MALFORMED_FRAME` / `FRAME_TOO_LARGE`。

## libgdp 的改动（已实现）

原来的 `quic_conn.cpp` 只接受 0 和 4 两条流，其他流一律 reset，也没有开额外流、接收额外流的 API。现在：

- **API**：客户端 `Connection::open_stream()`；host `allow_streams(n)` 加 `on_stream`。host 调 `allow_streams()` 之前，额外的流照旧按 §2.2 用 `UNSUPPORTED` reset。
- **MAX_STREAMS**：`allow_streams(4)` 放开 4 条，每关掉一条在 `stream_close` 里补一条（`MAX_STREAMS` 是累计值，ngtcp2 只对没报告过 open 的流自动补）。
- **发送优先级**：写循环按流 ID 从小到大取，control（0）、input（4）永远排在文件流（8 起）前面；代码里写明了这是有意的。
- **发送端反压**：新增 `on_acked(累计已确认字节)`（每次 dispatch 合并成一次），发送方照它补数据，不把整个文件塞进队列。
- **接收端反压**：额外的流要应用调 `Stream::consume()` 才归还这条流的接收额度；**连接级额度仍然一收到就归还**。最初设计想限制文件流在途的字节，实现时改成了这样：连接级额度永远不被文件流占住，4 条卡住的文件流也挡不住 StatsReport 和按键，每条流的内存上限就是它自己的窗口。
- **流的结束**：新增 `on_fin`、`on_reset`、`Stream::reset(code)`。释放一条自己一侧已经 FIN 的额外流时不 reset，只停止读取（STOP_SENDING），这样接收方回完 `failed` 就可以直接放手，回复不会丢。
- Ubuntu 26.04 的 ngtcp2 1.16 没有"收到 STOP_SENDING"的回调，所以 transport 不报告它；文件协议不需要，接收方停止读取之前一定先用 `FileReply` 说明原因。

测试：libgdp 新增 `additional_stream_test`（额度、补额度、FIN/reset、consume 反压、卡住时 control 照常通、优雅释放）和 `file_transfer_test`；wraith 新增 `file_receiver_test`（走真实 libgdp 回环：完整收到并保留 mtime、重名、拒绝、长度不符、两端取消、会话中途结束、协议错误，以及任何情况都不留临时文件）。Mac 上 libgdp 12 个测试普通和 ASan/UBSan 构建都通过；eq（Ubuntu 26.04）上整个仓库 33 个测试 `ctest -j4` 连续 3 次通过，新测试在 ASan 构建下也通过。

## 带宽和画面

- **上传（第一阶段）**：文件数据走客户端的上行，视频走下行，基本不冲突。但上行塞满时，客户端发出的 StatsReport（§7.5）、输入事件、ACK 都会排队，host 的码率控制会以为网络变差，画面质量下降。客户端要给上传限速：先按连接测出的 RTT 和丢包保守地控制，具体策略在实现时量过再定。界面上显示速度，让用户知道为什么慢。
- **下载（第二阶段）**：文件数据和视频抢下行，host 必须把文件流限制在码率控制预算的一部分以内，这是第二阶段的主要难点。

## 安全和隐私

- 只有认证过的 viewer 才能开 `file` 流；它能做的事情是往这个用户自己的下载目录里放新文件，不能覆盖、不能写到别处、不会执行任何东西。这和这个 viewer 本来就能用键盘鼠标做的事情相比，没有多出权限。
- 名字、大小都来自对方，按上面的规则检查；`size` 只用来做空间检查和计数，不用来一次性分配内存。
- 客户端只发送用户明确拖进来或选中的文件，不会自动发送任何东西，所以不需要像剪贴板那样的总开关（§17 "Privacy of the session"）。

## 第二阶段（只是方向，细节等第一阶段做完再定）

- host 上复制文件时，剪贴板里有 `text/uri-list` 或 `x-special/gnome-copied-files`。在 `file` 生效时，host 不发路径，而是发一份文件列表（名字、大小，每次复制一个编号），客户端提示"下载 host 复制的 N 个文件"。
- 用户确认后，客户端为每个文件开一条流，`FileOpen{request{列表编号, 序号}}`，host 回 `accepted` 后发字节，方向和第一阶段相反，其他规则一样。
- host 端限速，以及客户端的保存位置：macOS 用"下载"文件夹，iOS 用 App 的 Documents，在"文件" App 里可见。

## 客户端实现的要点（第一阶段）

- **GDPKit（已完成）**：`SessionClient` 管理每个文件的状态机（offer → 等 `accepted` → 发字节，最后一段带 FIN → 等 `saved`）。读文件不在这一层：上层收到 `fileAccepted` 之后自己读、用 `sendFileData` 往里送，按 `fileProgress`（host 已确认的字节数，只算文件内容，不算开头那一帧）控制在途的量，整个文件不会一次进内存。结果只有一次 `fileFinished`：`saved(name)`、`refused(错误)`、`failed(错误)`、`cancelledByHost`、`timedOut`、`connectionEnded`；连接断开时先报告所有未完成的传输，再报告会话结束。客户端自己 `cancelFile` 时直接 reset，不再回调。名字在 Swift 层先转成 NFC 再交给 C++ 检查。客户端不接受 host 开的流，libgdp 已经按 §2.2 拒绝了。
  - 测试 13 个（`FileTransferTests`）：名字和修改时间、NFC、重名编号、8 MiB 按确认量送数据、空文件、一次超过 4 个（流配额补回）、不合法的名字、没有 capability、拒绝、中途失败后会话照常、超时、取消、连接断开、超出大小的数据不发。回环上 8 MiB 用时约 57 ms。
- **测试 host**：`GDPTestHost` 已经能收文件（内存里），可以故意拒绝、中途失败、不回复。还没做的：`LoopbackHost`（App 的 loopback 模式）存到临时目录、在每秒的日志里打印文件名和大小。
- **SpectreKit `FileTransfer`**：队列（最多 4 个同时传）、进度、取消、重试；macOS 的 security-scoped URL，iOS 用 `NSFileCoordinator` 读取（iCloud 里还没下载的文件会先下载）；读取过程中文件大小变了，就当作失败。
- **macOS**：拖进会话窗口；工具栏"发送文件…"（`NSOpenPanel`，需要 `com.apple.security.files.user-selected.read-only`）；传输列表显示进度、可以取消。
- **iOS / iPadOS**：工具栏菜单里用 `fileImporter`；iPad 可以拖放；进入后台时用 `beginBackgroundTask` 争取时间，时间到了就当作取消。
