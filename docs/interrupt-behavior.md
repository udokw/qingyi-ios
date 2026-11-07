# 局域网对局中断行为审查

> 审查方式：**纯代码路径审查**。本机为 Windows，无法编译 Swift 或运行 iOS 模拟器/真机，以下结论均来自源码走读，**不代表已真机验证**。
> 仓库版本：v1.0.2（`project.yml` / `LanHub.appVersion` / 首页页脚三处一致）。
> 相关文件：`QingYi/Net/LanHub.swift`、`LanFrame.swift`、`LanHost.swift`、`LanClient.swift`、`LanDiscovery.swift`、`QingYi/UI/LanGameView.swift`、`LanLobbyView.swift`、`MainView.swift`。

## 结论摘要

- iOS 侧**没有任何"连接关闭 → dismiss 当前页"的代码路径**。断线时页面停在棋盘，时钟冻结，120 秒内自动重连；超时后原地显示中文结果，不会退出 App。
- 不存在 Android 那种"`session` 为空就 `finish()` 唯一页面"的等价风险：iOS 没有对局持久化，进程被回收后重启回到首页；即便对局页在无 session 的情况下被渲染，棋盘视图也有边界保护，不会数组越界。
- 主动"离开房间"是唯一会关闭联机全屏页的入口，且只有一次 `dismiss()`；连接关闭回调会被 `attemptSeq` 守卫丢弃，不会二次关闭。
- 本次审查发现并修复了 4 个问题（后台恢复误判、断线结束后状态显示错误、开局前断线卡死界面、`LanHost.send` 跨线程引用访问）。

## 行为矩阵

| # | 场景 | 代码路径 | 实际行为 | 是否符合预期 | 风险 |
|---|---|---|---|---|---|
| 1 | 对局中对方退出/杀进程 → 客机侧 | `LanFrame.swift:66-74` 收到 `.failed/.cancelled` → `LanFrame.swift:151` `close` → `LanClient.swift:32` `onClosed` → `LanHub.swift:958` `onClientClosed` → `LanHub.swift:1607` `onClientLinkLost` → `LanHub.swift:1617` `startReconnect` | 停在棋盘；顶部变"重连中"（`LanGameView.swift:29/94`）；时钟冻结（`LanHub.swift:1783-1804`，`linkDown`/`clockFrozen` 时不再递减）；每 1.5s 重连一次 | 是 | 无退出/闪退路径 |
| 1b | 同上，120 秒后 | `LanHub.swift:1693` `failReconnect` → `LanHub.swift:958` 已设置 `resultDetail` → `LanGameView.swift:48` 弹结果层 | 原地显示"对局结束"、中文详情（"与房主的连接未能恢复…"）、"离开房间"按钮；**不 dismiss** | 是 | 状态文案已修正，不再一直显示"重连中" |
| 2 | 对局中客机断线 → 房主侧 | `LanHost.swift:183` `detach` → `onGuestChanged(false)` → `LanHub.swift:843` → `LanHub.swift:1569` `onHostLinkLost` → `LanHub.swift:1588` `scheduleGrace` | 立即 `clock.pauseAt(最后一次收包时刻)` 并广播暂停后的时钟；0.3s 后释放客机槽位；120s 后 `LanHub.swift:1198` `hostFinishPayload` + `LanHub.swift:591` `resultByDisconnect` | 是 | 宽限计时受前后台保护（见 #4） |
| 3 | Wi-Fi 切换/飞行模式 | `.failed` 走 #1；`.waiting` 不关闭连接，改由静默检测：房主心跳 5s、房主判定 13s、客机判定 15s；随后进入同一个 `onLinkLost → startReconnect` 路径 | 与"对方退出"完全同一套处理；重连目标为**上次的 IP:端口** | 部分 | 若**房主 IP 变化**（房主切 Wi-Fi），客机重连旧 IP 必然失败，只能等 120s 判负；不会重新走 mDNS 发现。与 Android 行为一致，未改协议 |
| 4 | 切后台/回前台 | `LanLobbyView.swift:67` 监听 `scenePhase` → `LanHub.swift:1537/1549` | 进后台：收回本地重连任务与宽限计时（`appInBackground=true`，`linkWatchTick`/宽限/重连循环全部跳过）。回前台：若已断线，重新给**完整 120s**；若未断线，重置收包时间并立刻发一次 ping，避免"一回来就误判" | 是（本次修复） | 对手端（尤其 Android）仍在按自己的 120s 计时，后台超过 120s 仍会被判负，这是协议层行为 |
| 4b | 后台期间计时 | `LanClock` 使用 `ProcessInfo.systemUptime`，`LanHub.swift:1759-1773` | 进程挂起时 `tick` 不执行；回到前台后按实际经过时间结算。设备深睡时 `systemUptime` 暂停，不会凭空扣时 | 是 | 主动切后台的玩家会正常消耗自己的思考时间（属于规则内），不会"误判负" |
| 5 | 主动点"离开房间"（对局未结束） | `LanGameView.swift:60-63` 二次确认 → `LanGameView.swift:311` `leave()` → `LanHub.swift:1822` `stop()` → `dismiss()` | 先确认；确认后关闭整个联机全屏页，回到 **App 主页**（不是联机大厅）。`stop()` 在 `client.close()` 之前 `attemptSeq += 1`（`LanHub.swift:1833/1837`），关闭回调被守卫丢弃；房主侧 `detach` 回调到达时状态已是 `.idle`，`onGuestChanged` 直接返回 | 是 | 只有一次 dismiss，无双重关闭。对手端需等满 120s 才判负（未发送 `game_over`，与 Android 一致） |
| 6 | 结果页"离开房间" | `LanGameView.swift:296-298` → `LanGameView.swift:311` | 同 #5，回到 App 主页 | 是 | 同上 |
| 7 | 进程被系统回收后重建 | 无持久化；`LanHub.swift:718` 单例重新初始化，`state = .idle`；`MainView.swift:103-106` 的 cover 不会被自动恢复 | 重启后停在 App 主页，不进入对局页 | 是 | 不存在"空 session 的页面被 pop/finish"风险。即使误入对局页，`GoBoardView.swift:22-23/57-58/78`、`XiangqiBoardView.swift:23` 均有边界保护，空棋盘只画网格不崩溃 |

## 崩溃写法排查

| 检查项 | 命中位置 | 结论 | 是否需要改 |
|---|---|---|---|
| 强制解包 `!` | `LanHub.swift:540` `g.toGtp(m.point!.x, m.point!.y)` | 同一三元表达式先判 `m.point == nil`，短路求值，安全 | 否 |
| `try!` | Net/联机 UI 全目录 | 无 | 否 |
| `fatalError` / `precondition` / `assert` | Net/联机 UI 全目录 | 无 | 否 |
| 数组越界 | `LanHub.swift:315-316`（历史串拆分，前面已 `guard count >= 3`）；棋盘视图全部 `min()/guard`；`LanClock` 固定 2 元素、下标只来自 `seat-1`；`GoGame` 尺寸被夹到 2…25 | 未发现可触达的越界 | 否 |
| 非主线程更新 `@Published`/UI | `LanHub` 整体 `@MainActor`；`LanHost/LanClient` 回调统一 `Task { @MainActor in ... }`（`LanHub.swift:765-770`、`LanHub.swift:843-856`）；`LanDiscovery.publish` 回主线程（`LanDiscovery.swift:188`） | 无后台线程直接改 UI 状态 | 否 |
| `NWConnection` 回调访问已释放对象 | `LanFrame.swift:66/90` 等全部 `[weak self]`；连接对象由 Host/Client 强持有 | 安全 | 否 |
| 跨线程读取房主内部状态 | `LanHost.send` 原来在主线程同步读 `guest` 引用；`hasGuest/isGuestHandshaked/guestIdleSeconds` 也是跨队列读 | ARC 竞态，理论上有极小概率崩溃/读到脏值 | **已改**：`send` 改为入队执行（`LanHost.swift:196-202`），删除未使用的跨队列访问器，`hasGuest` 改用主线程镜像 `guestPresent`（`LanHub.swift:668/733/844/1844`） |
| 连接关闭回调重复触发 | `LanHub.swift:1822-1837` 先 `attemptSeq += 1` 再 `close()`；`LanHost.detach` 用 `guest === client` 判重（`LanHost.swift:183-191`） | 不会双触发 | 否 |
| 断线后状态残留 | `failReconnect` 保留 `linkDown=true` | 结果页与"重连中"同时出现 | **已改**：`LanGameView.swift:94-97` 在 `.finished` 时显示"已结束"，且 `LanGameView.swift:29` 只在 `.playing` 时显示重连横幅 |
| 已进房未开局断线 | `LanHub.swift:958` | 原来停在"等待房主开局"的死界面 | **已改**：转为 `.error` 并提示"与房主的连接已断开"，可点返回 |

## 本次修复清单（v1.0.2）

1. **后台恢复误判**：新增 `appMovedToBackground()` / `appMovedToForeground()`（`LanHub.swift:1537/1549`），并在宽限任务、链路巡检、重连循环中检查 `appInBackground`（`LanHub.swift:1588-1605`、`1617-1691`、`1718-1737`），后台时间不再计入 120s 宽限。
2. **断线结束后仍显示"重连中"**：`LanGameView.swift:94-97` 新增 `statusText`，`.finished` 显示"已结束"；重连横幅只在 `.playing` 出现（`LanGameView.swift:29`）。
3. **开局前断线卡死**：`LanHub.swift:958-966` 在 `.lobby` 状态收到连接关闭时转入 `.error` 并显示原因。
4. **跨线程访问客机引用**：`LanHost.send` 改为串行队列内发送（`LanHost.swift:196-202`）；删除 `hasGuest/isGuestHandshaked/guestIdleSeconds` 三个跨队列访问器；`guestPresent` 作为主线程镜像（`LanHub.swift:668/733/844/1844`）。
5. 顺带删除两个未使用的 `idleSeconds` 计算属性（`LanClient`、`LanFrame`）。

## 已知限制（未改，属于协议/行为取舍）

- 房主主动"离开房间"不会给客机发 `game_over`，客机要等满 120s 才判负；与 Android 现状一致。
- 客机重连只重试上次的 `IP:端口`，不会重新做 mDNS 发现；房主换网段后无法自动恢复。
- iOS 无对局持久化：进程被杀后无法自动续局（对局在房主侧仍保留 120s 宽限，但客机需重新加入才会拿到快照）。
- 计时使用 `systemUptime`，设备深睡时不计时；不会误判负，但极端情况下双方显示可能略有差异。

---

## 真机自测清单（侧载 v1.0.2 后逐条验证）

准备：两台设备同一 Wi-Fi；一台装 Android 清弈，一台装本 IPA。首次进入联机时允许"本地网络"权限。

| 步骤 | 操作 | 预期 |
|---|---|---|
| 1 | iOS 建房（围棋），Android 加入 | 双方看到同一房号、执子方、`IP:端口`；iOS 点击开始后双方进入同一棋盘 |
| 2 | 对局中，**客机**按 Home 键回桌面（不杀进程），立即返回 | iOS 房主侧顶部短暂显示"重连中"，随后恢复"在线"；时钟不跳负；可继续落子 |
| 3 | 对局中，**房主**按 Home 键 5 秒后返回 | 客机侧不判负；房主回来后立即恢复心跳；对局可继续 |
| 4 | 对局中，客机开飞行模式 10 秒后关闭 | 客机停在棋盘、顶部"重连中"、时钟冻结；10 秒内自动恢复为"在线"；落子正常 |
| 5 | 对局中，客机**直接杀进程** | 客机重启后回到 App 主页（不闪退）；房主侧显示"对手已断开，计时已暂停"，120s 后弹出中文结果（对手断线判负） |
| 6 | 对局中，房主**直接杀进程** | 客机停在棋盘显示"重连中"，时钟冻结；120s 后原地弹出"对局结束 + 与房主的连接未能恢复…"，**不退出 App** |
| 7 | 对局中，客机点"离开"→ 确认 | 弹二次确认；确认后回到 App 主页；房主侧走宽限/判负流程，不闪退 |
| 8 | 结果页点"离开房间" | 回到 App 主页（不是联机大厅） |
| 9 | 已加入房间、**房主尚未开始**时，房主退出 | 客机不再卡在"等待房主开局"，显示"与房主的连接已断开"并可返回 |
| 10 | 切后台超过 2 分钟再回来（对手保持前台） | 客机应显示对局已结束（对手端已按 120s 判负），App 本身不崩溃、不闪退 |
| 11 | 象棋对局，黑方视角 | 自己的棋子在下部；点击落点与高亮一致（若出现棋子文字倒置属于显示问题，不影响连接安全） |

> 以上均为"代码路径审查 + 待真机确认"。若某一步与预期不符，请记录：设备、步骤、界面截图、是否闪退，再对照本文件的 file:line 定位。
