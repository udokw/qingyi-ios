# 联机协议对照（Android ↔ iOS）

本文逐字段对照 Android 端实现与 iOS 端实现。**Android 代码是唯一权威**（`app/src/main/java/com/sijia/go/net/*.java`）；`docs/lan-multiplayer-design.md` 中落后于代码的数值以本文和代码为准。

核对方式：逐行阅读两端源码做静态比对。本机无 macOS/Xcode，iOS 侧通过 GitHub Actions（macOS 无签名构建）编译验证；**尚未真机运行**，协议结论仍属静态核对，未经 Android ↔ iOS 真机互通验证。

参考实现：

| 层 | Android | iOS |
| --- | --- | --- |
| 常量 | `net/Proto.java` | `QingYi/Net/LanProto.swift` |
| 分帧 | `net/FrameIO.java` | `QingYi/Net/LanFrame.swift` |
| 发现 / 探活 | `net/LanDiscovery.java`、`LanLobbyActivity.java` | `QingYi/Net/LanDiscovery.swift` |
| 房主监听 | `net/LanHost.java` | `QingYi/Net/LanHost.swift` |
| 客机连接 | `net/LanClient.java` | `QingYi/Net/LanClient.swift` |
| 状态机 | `net/LanHub.java`、`LanSession.java`、`LanClock.java` | `QingYi/Net/LanHub.swift` |
| 规则 / 哈希 | `net/GoRules.java`、`XiangqiRules.java`、`BoardHash.java` | `QingYi/Net/LanHub.swift`（`LanGameSession`） |

## 1. 分帧

| 项目 | Android | iOS | 状态 |
| --- | --- | --- | --- |
| 长度前缀 | 4 字节大端 | 4 字节大端（`UInt32` → 大端写入） | 一致 |
| 编码 | UTF-8 JSON | UTF-8 JSON | 一致 |
| 单帧上限 | `MAX_FRAME = 65536` | `LanProto.maxFrame = 65_536` | 一致 |
| 超限处理 | 抛错并断开 | 抛 `LanFrameError.tooLarge` | 一致 |
| 半包处理 | 读满再解析，残留保留 | `LanFrame.decode` 就地消费缓冲区，不足返回 nil | 一致 |

## 2. 信封

两端都是 `{"v":1,"t":<type>,"sid":<uuid>,"ts":<ms>,"seq":0,"room":<code>,"from":"host"|"guest","p":{...}}`。

| 键 | Android | iOS | 状态 |
| --- | --- | --- | --- |
| `v` | `Proto.VERSION = 1` | `LanProto.version = 1` | 一致 |
| `t` | 消息类型字符串 | 同 | 一致 |
| `sid` | 12 位小写 hex（UUID 去横线前 12 位） | `LanProto.newSessionId()` 同规则 | 一致 |
| `ts` | `System.currentTimeMillis()` | `LanProto.nowMs()`（`Date` 毫秒） | 一致（均为 Unix 毫秒） |
| `seq` | 恒为 0，未使用 | 恒为 0 | 一致 |
| `room` | 房间码（探活消息同样带） | 同 | 一致 |
| `from` | `"host"` / `"guest"` | 同 | 一致 |
| `p` | 载荷对象，缺省空对象 | 同 | 一致 |

## 3. 消息类型

两端常量字符串完全一致，共 24 个：

`hello`、`hello_ack`、`hello_reject`、`lobby`、`ready`、`game_start`、`move`、`move_ack`、`move_reject`、`state_snapshot`、`sync_request`、`undo_request`、`undo_response`、`undo_applied`、`resign`、`draw_offer`、`draw_response`、`clock`、`ping`、`pong`、`probe`、`probe_ack`、`game_over`、`bye`。

`lobby` / `ready` / `draw_offer` / `draw_response` 两端都只定义、未使用；iOS 一并定义以保持类型表完整。

## 4. 各消息载荷（`p`）

### 4.1 hello（客机 → 房主）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `protocolVersion` | int | 与 `v` 相同，房主二次校验 |
| `roomCode` | string | 房主比对，不符回 `E_ROOM_CODE` |
| `deviceName` | string | 昵称 |
| `platform` | string | Android 为 `"android"`，iOS 为 `"ios"`（仅展示） |
| `appVersion` | string | 版本号，仅展示/排查 |
| `clientId` | string | 客机实例 id |
| `game` | string | 可选；`"go"` / `"xiangqi"`，房主比对，不符回 `E_GAME_MISMATCH` |
| `resume` | bool | 可选，断线重连时为 `true` |
| `gameId` | string | 仅重连时携带，必须等于当前对局 `matchId`，否则 `E_NO_GAME` |
| `moveNo` | int | 仅重连时携带，房主的权威手数 |

### 4.2 hello_ack（房主 → 客机）

正常开局握手：

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `ok` | bool | `true` |
| `game` | string | 棋种 |
| `gameId` | string | 对局 id |
| `size` | int | 围棋 19，象棋 9 |
| `komi` | double | 围棋贴目（7.5），象棋 0 |
| `seat` | int | 客机席位，固定 `1` |
| `yourColor` | string | 围棋 `"B"`/`"W"`，象棋 `"R"`/`"B"` |
| `opponentName` | string | 房主昵称 |
| `hostPlatform` | string | 房主平台 |
| `ruleset` | string | `"chinese-simple-ko"`（仅展示） |
| `serverTime` | int64 | 房主 Unix 毫秒 |
| `room` | string | 房间码回显（可选，客机缺省沿用本地） |

断线恢复（`resume=true` 时）：

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `ok` | bool | `true` |
| `resumed` | bool | `true` |
| `game` / `gameId` / `size` / `komi` | — | 同上 |
| `moveNo` | int | 当前手数 |
| `yourColor` | string | 客机颜色 |
| `opponentName` | string | 房主昵称 |
| `snapshot` | object | 完整快照，见第 6 节 |
| `clock` | object | 时钟快照，见 4.7 |

### 4.3 hello_reject（房主 → 客机）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `code` | string | `E_ROOM_CODE`、`E_VERSION`、`E_GAME_MISMATCH`、`E_NO_GAME`、`E_ALREADY_PLAYING` |
| `message` | string | 中文说明 |
| `ok` | bool | iOS 额外发送 `false`；Android 无此键，读取端忽略，不影响互通 |

### 4.4 game_start（房主 → 客机）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `game` | string | 棋种 |
| `gameId` | string | 对局 id |
| `size` | int | 19 / 9 |
| `komi` | double | 围棋贴目 |
| `handicap` | int | 恒 0 |
| `handicapPoints` | array | 恒空数组 |
| `ruleset` | string | `"chinese-simple-ko"`（围棋）/ `"xiangqi"` |
| `toMove` | string | 先手颜色字符（`"B"` / `"R"`） |
| `seats` | array | 两项：`[{seat:0,name,color,kind:"human"}, {seat:1,name,color,kind:"human"}]`，`seat` 0 为房主、1 为客机 |
| `timeControl` | object | `{mode, mainSec, byoYomiSec, periods, incrementSec}`，`mode` 为 `"none"`/`"byoyomi"`，`incrementSec` 恒 0 |
| `startAtHostMs` | int64 | 房主 Unix 毫秒 |

客机收到后：清空本地局面、按 `seat` 设 `myColor`、`state = playing`、重置时钟并启动链路看门狗。

### 4.5 move（客机 → 房主）

围棋：`pass`(bool)、`x`(int)、`y`(int)，停一手时 `x = y = -1`。
象棋：`fx`、`fy`、`tx`、`ty`(int)、`uci`(string)。

两端共有：`moveNo`（期望的下一手手数）、`color`（行棋方颜色字符）、`hashBefore`（落子前局面哈希）。

### 4.6 move_ack（房主 → 客机）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `moveNo` | int | 房主结算后的手数 |
| `pass` | bool | 围棋是否停一手 |
| `x` / `y` | int | 围棋落点，-1 表示停一手 |
| `fx` / `fy` / `tx` / `ty` | int | 象棋坐标（围棋时为 -1） |
| `captured` | int | 提子数 / 吃子数（象棋 0 或 1） |
| `nextTurn` | string | 下一手颜色字符 |
| `hash` | string | 落子后局面哈希 |
| `clock` | object | 计时开启时附带 |

### 4.7 move_reject（房主 → 客机）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `moveNo` | int | 客机发来的手数（回显） |
| `code` | string | `E_STALE_MOVE`、`E_OUT_OF_TURN`、`E_HASH_MISMATCH`、`E_ILLEGAL_MOVE`、`E_OCCUPIED`、`E_KO`、`E_SUICIDE` |
| `message` | string | 中文原因 |
| `authoritativeMoveNo` | int | 房主权威手数 |
| `hash` | string | 房主权威哈希 |
| `snapshot` | object | **仅** `E_HASH_MISMATCH` 时附带完整快照 |

校验顺序两端一致：手数 → 行棋方 → `hashBefore` → 规则合法性。

### 4.8 state_snapshot（房主 → 客机）与 sync_request（客机 → 房主）

`sync_request` 的 `p` 为空对象；房主回一条 `state_snapshot`，其 `p` 即第 6 节的完整快照。
客机在 `move_ack` 校验失败或链路恢复时主动请求。

### 4.9 悔棋

| 消息 | 方向 | `p` 字段 |
| --- | --- | --- |
| `undo_request` | 任一方 → 对方 | `count`(int，默认 1)、`moveNo`(int) |
| `undo_response` | 被请求方 → 请求方 | `accept`(bool) |
| `undo_applied` | 房主 → 客机 | `moveNo`(int)、`hash`(string)、`snapshot`(object) |

房主是唯一执行方：客机请求 → 房主同意后 `undo` 并广播 `undo_applied`；房主请求 → 客机同意后房主本地 `undo` 并广播。撤子数上限 2。

### 4.10 认输 / 数子 / 结束

| 消息 | 方向 | `p` 字段 |
| --- | --- | --- |
| `resign` | 任一方 → 房主 | `by`(颜色字符) |
| `game_over` | 房主 → 客机 | `game`、`moveNo`、`komi`，加结果字段（见下） |

结果字段（围棋与象棋同结构，`result` 一律是**字符串**）：

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `result` | string | 围棋：`"B+R"`、`"W+T"`、`"B+3.5"`、`"draw"`；象棋：`"R"`、`"B"`、`"draw"` |
| `detail` | string | 中文描述，两端逐字一致 |
| `reason` | string | `rule` / `score` / `resign` / `timeout` / `disconnect` |
| `blackScore` | double | 围棋数子结果；认输/超时/断线时为 -1 |
| `whiteScore` | double | 同上 |

`detail` 文案对照（均已逐字核对）：

- 围棋认输：`黑方认输，白方中盘胜`（`中盘胜` 仅围棋）
- 围棋超时：`黑方超时，白方胜`
- 围棋断线：`黑方断线，白方中盘胜`
- 象棋认输：`红方认输，黑方胜`
- 数子：`黑胜 3.5 目\n黑 185 : 白 181.5（含贴目 7.5）`（`%.1f`，换行符 `\n`）

### 4.11 clock（房主 → 客机）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `turn` | string | 当前行棋方，**抽象色位**：`"B"` = 下标 0（围棋黑 / 象棋红）、`"W"` = 下标 1 |
| `blackRemainMs` | int64 | 黑/红方主时剩余 |
| `whiteRemainMs` | int64 | 白/黑方主时剩余 |
| `blackPeriods` | int | 黑/红方剩余读秒次数 |
| `whitePeriods` | int | 白/黑方剩余读秒次数 |
| `blackByoYomi` | bool | 黑/红方是否已进入读秒 |
| `whiteByoYomi` | bool | 白/黑方是否已进入读秒 |
| `running` | bool | 是否正在走秒 |
| `paused` | bool | 是否暂停（宽限期） |
| `moveNo` | int | 手数 |
| `serverTime` | int64 | 房主 Unix 毫秒 |

### 4.12 ping / pong

`ping`：`p` 含 `t0`(int64，房主 Unix 毫秒)。`pong`：回显 `t0` 并附 `serverTime`。
房主每 5 秒发一次 `ping`，客机收到立即回 `pong`；两端都把「任意收到帧」刷新为链路活跃。

### 4.13 probe / probe_ack

`probe`（客机 → 房主）：`p` 为空对象，房间码放在信封 `room`。
`probe_ack`（房主 → 客机）：`p` 为房主的探活信息：

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `room` | string | 房间码，客机用它丢弃过期回包 |
| `game` | string | `"go"` / `"xiangqi"` |
| `iid` | string | 房主实例 id（同一房主的多条 mDNS 记录据此去重） |
| `pid` | int | 进程号 |
| `ts` | int64 | Unix 毫秒 |
| `state` | string | `"waiting"` / `"playing"` |

房主对 probe 连接只读首帧、回 `probe_ack` 后**立即关闭**，不占客机槽位、不影响状态。客机探活结果枚举：`ALIVE = 1`、`STALE = -1`、`DEAD = 0`、`UNKNOWN = 2`。

### 4.14 bye

`p` 为空。两端都只处理接收，用于提示「对方已离开房间」。

## 5. Bonjour（mDNS）

| 项目 | Android | iOS | 状态 |
| --- | --- | --- | --- |
| 主服务类型 | `_qingyi._tcp.`（`NsdManager` 需要结尾点） | `_qingyi._tcp`（Network 框架不带点） | 同一 DNS-SD 类型 |
| 额外广告类型 | 无 | `_qingyi-go._tcp`、`_qingyi-xiangqi._tcp`（`NetService`，仅广告） | iOS 单向扩展，不影响 Android |
| 浏览类型数 | 1 | 3（按 `iid` 去重、按 `game` 过滤） | iOS 兼容 Android |
| 服务名 | `QY-<room>-<size>` | 同 | 一致 |
| TXT `room` | 房间码，4 位，字母表去掉 I/L/O/U | 同 | 一致 |
| TXT `size` | 19 / 9 | 同 | 一致 |
| TXT `game` | `"go"` / `"xiangqi"` | 同 | 一致 |
| TXT `port` | 实际监听端口 | 同 | 一致 |
| TXT `addr` | 本机 IPv4 字面量 | 同（`getifaddrs` 取，优先 en0/en1） | 一致 |
| TXT `pid` | 进程号 | 同 | 一致 |
| TXT `iid` | 实例 id | 同 | 一致 |
| TXT `ts` | Unix 毫秒 | 同 | 一致 |
| 端口起点 / 重试 | 41234，连续 11 个端口 | 同 | 一致 |

> 说明：iOS 的 `NSBonjourServices` 必须列出三种不带点的类型，否则系统会拦截对应的浏览/发布。

## 6. 快照

快照同时用于 `state_snapshot`、`hello_ack(snapshot)`、`undo_applied`、`move_reject`。

### 6.1 公共外层（`LanSession.snapshot()`）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `gameId` | string | 对局 id |
| `game` | string | `"go"` / `"xiangqi"` |
| `moveNo` | int | 手数 |
| `consecutivePasses` | int | 连续停一手次数（围棋） |
| `hash` | string | 当前局面哈希 |

### 6.2 围棋（`GoRules.snapshot()`）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `size` | int | 19 |
| `komi` | double | 7.5 |
| `toMove` | string | `"B"` / `"W"` |
| `ko` | array | `[x, y]`，无劫时为 `[-1, -1]` |
| `board` | string | 自第 0 行起，每行 19 个字符 `'0'/'1'/'2'`，行间 `/` 连接 |
| `moves` | array | 按**时间正序**的 `[colorChar, x, y]`，停一手为 `[color, -1, -1]` |

> 两端 `history` 的存储顺序相反：Android 为「最新在前」（快照时 reverse），iOS 为「最早在前」（直接输出）。**快照里的顺序一致，均为正序**。

恢复时两端都**忽略** `board`/`ko`/`toMove`，只按 `moves` 重放。

### 6.3 象棋（`XiangqiRules.snapshot()`）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `size` | int | 9 |
| `fen` | string | 标准 FEN |
| `toMove` | string | `"R"` / `"B"` |
| `result` | int | 0 未结束、1 红胜、2 黑胜、3 和棋 |
| `endReason` | string | 中文结束原因，空字符串表示未结束 |
| `moves` | array | 按时间正序的 `[uci, fx, fy, tx, ty]` |

恢复时优先按 `moves`（5 元素用坐标、否则用 `uci`）重放，`moves` 为空才回退 `fen`。

## 7. 哈希

### 7.1 围棋 — SHA-256 完整 64 位 hex

规范化串：

```
1|SZ=<size>|M=<moveNo>|T=<B|W>|K=<koX>,<koY>|<第0行>/<第1行>/.../<第18行>
```

每格用 `GoColor.rawValue`（`0` 空、`1` 黑、`2` 白）拼成字符，行间 `/`，无劫时 `K=-1,-1`。结果取 SHA-256 的**完整 64 字符小写 hex**。

> 注意：任务描述里「围棋取前 8 字节」与 Android 代码不符，代码是完整 hex，iOS 已按**完整 hex** 实现（`LanProto.sha256Hex`）。

### 7.2 象棋 — SHA-256 前 8 字节

```
<hash 输入> = <positionKey>|M=<moveNo>
<positionKey> = 逐行拼接的 90 个字符 + 行棋方（1 红 / 2 黑）
```

字符编码：空格 `'a'`（0）、红方 `type + 1`（`'b'`..`'h'`）、黑方 `type + 8`（`'i'`..`'o'`），`type` 为 `0..6`（帅/仕/相/马/车/炮/兵）。

iOS 原有的 `XiangqiGame.positionKey` 字母表不同（`'i'..'o'`/`'q'..'w'`），因此联机层单独实现 `LanGameSession.compatPositionKey`，与 Android 逐字节对齐。

哈希取 SHA-256 前 8 字节 → 16 位小写 hex（`LanProto.sha256Prefix8`）。

## 8. 时间与超时常量

| 常量 | Android | iOS | 状态 |
| --- | --- | --- | --- |
| 重连宽限 | `RECONNECT_GRACE_MS = 120000` | `reconnectGraceMs = 120_000` | 一致（设计文档写 60s，已过时） |
| 链路静默（房主） | `LINK_IDLE_MS = 13000` | `hostIdleMs = 13_000` | 一致 |
| 链路静默（客机） | `LINK_IDLE_MS + 2000 = 15000` | `guestIdleMs = 15_000` | 一致 |
| 房主 ping 间隔 | 5000 | `hostPingMs = 5_000` | 一致 |
| 客机重连间隔 | 1500 | `guestReconnectMs = 1_500` | 一致 |
| 房主首帧超时 | `setSoTimeout(3000)` | `hostFirstFrameMs = 3_000` | 一致 |
| hello 等待 | `HELLO_WAIT_MS` | `waitHello(timeout: 6)` | 一致 |
| 探活连接超时 | 首次 1200 / 后续 1500 | `probeFirstTimeoutMs = 1_200` / `probeTimeoutMs = 1_500` | 一致 |
| 探活读超时 | 1200 / 1500 / 重试 2000 | 同（内部按上述两档） | 一致 |
| 发现复核周期 | 3500 | `probeIntervalMs = 3_500` | 一致 |
| 条目 TTL | 15000 | `probeTtlMs = 15_000` | 一致 |
| 新条目验证宽限 | 6000 | `newEntryGraceMs = 6_000` | 一致 |
| 发现轮询 | 800 | 0.8s | 一致 |

## 9. 已知差异（均不影响互通）

1. **iOS 多发布两个棋种专用服务类型**：Android 只浏览 `_qingyi._tcp`，看不到额外类型；iOS 客机浏览三种并去重，可同时兼容两端。
2. **`hello_reject` 多一个 `ok:false`**：Android 读取端只用 `code`/`message`，多余键被忽略。
3. **`state_snapshot` 由 iOS 主动回**：两端流程一致，均用于 `sync_request` 之后。
4. **`bye` 两端都不发送**：仅保留接收处理。
5. **错误提示文案略有差异**（如「还没轮到你落子」）：`code` 一致，仅 UI 文案不同。
6. **探活 `STALE(-1)` 未单独保留**：iOS 收到非 `probe_ack` 或校验不过的回包按「删除」处理，Android 侧等同于判死，行为一致。
7. **iOS 依赖 TXT `addr` 连接**：未使用 SRV 解析出的主机名回退。Android 房主总是写入 IPv4，正常局域网可用；若某设备 TXT 缺 `addr`，iOS 无法加入（Android 可用 SRV 回退）。这是已知限制。

## 10. 断线与前后台

- 断线只暂停时钟并保留棋盘，**不结束对局、不退出页面**；`LanGameView` / `LanLobbyView` 没有任何在连接关闭时 `dismiss()` 的路径。
- 宽限期内（120 秒）重连成功即恢复对局；超时才判负，结果原因码为 `disconnect`。
- 客机重连循环与房主宽限计时都是本地实现，不新增协议字段，Android 侧无感知。
- App 进入后台时系统会挂起进程：iOS 会收回本地重连/宽限计时，回到前台后重新给一轮完整宽限，避免「切出去一会儿回来就判负」。注意房主若不在后台，仍按协议在 120 秒后判负；这一点与 Android 一致。

## 11. 尚未验证（需真机 / CI 确认）

| 项 | 风险 |
| --- | --- |
| ~~全部 iOS 代码能否编译~~ | 已验证：GitHub Actions run `42356180389` 无签名构建通过（2026-11-07），产物 `QingYi-unsigned-ipa` |
| iOS ↔ Android 实际互通 | 需两台真机在同一 Wi-Fi 下完成：发现 → 探活 → 加入 → 开局 → 落子 → 悔棋 → 认输 → 断线重连 |
| Bonjour 类型写法 | Network 框架用不带点的 `_qingyi._tcp`；`NSBonjourServices` 同样不带点。若发现不到，优先怀疑此处 |
| `NWTXTRecord.dictionary` 键值 | 依赖系统把 TXT 解析成字符串字典，需真机确认 |
| 棋盘翻转后的点击坐标 | 客机席位置反转依赖 SwiftUI 对旋转视图的命中测试 |
| `String(format: "%.1f")` 的地区差异 | 若系统区域设置使用逗号小数点会与 Android 不同 |

以上均标注为**未编译验证**。
