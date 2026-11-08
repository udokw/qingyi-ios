import Foundation
import CryptoKit
import Darwin

/// 联机协议常量与信封。对端实现：Android `com.sijia.go.net.Proto`。
enum LanProto {
    static let version = 1

    /// 统一服务类型：围棋/象棋共用一个发现入口，棋种放在 TXT 的 game 字段。
    /// Network 框架使用不带尾点的形式；NetService / NSBonjourServices 使用带尾点的形式。
    static let serviceTypeNW = "_qingyi._tcp"
    static let serviceTypeMDNS = "_qingyi._tcp."
    /// 棋种专用类型：房主额外广告，仅作兼容与未来扩展，发现端按 game 过滤。
    static let goServiceTypeNW = "_qingyi-go._tcp"
    static let xqServiceTypeNW = "_qingyi-xiangqi._tcp"
    static let allServiceTypesNW = [serviceTypeNW, goServiceTypeNW, xqServiceTypeNW]
    static let allServiceTypesMDNS = ["_qingyi._tcp.", "_qingyi-go._tcp.", "_qingyi-xiangqi._tcp."]

    static let defaultPort: UInt16 = 41234
    static let portTries = 11
    /// 同一端口 bind 失败时先原地重试的次数（等待上一个监听器的 socket 真正释放）。
    static let samePortRetries = 3

    /// 手动加入时依次尝试的端口：与建房的候选端口集合完全一致。
    static var portCandidates: [UInt16] {
        (0..<portTries).map { UInt16(Int(defaultPort) + $0) }
    }

    /// UDP 房号查询端口。真正的 TCP 监听端口由系统分配并通过 TXT / UDP 应答下发，
    /// 这里只用于「只填房号」时定向找房主（与 Android `Proto.QUERY_PORT` 一致）。
    static let queryPort: UInt16 = 41235
    static let roomQueryType = LanUdpTypes.query
    static let roomReplyType = LanUdpTypes.reply
    /// 房主周期性广播的房间通告（mDNS 失效时的并行发现通道）
    static let roomAnnounceType = LanUdpTypes.announce
    static let announceIntervalMs: Int64 = 3_000

    /// 房号固定 4 位，且从 1.1.6 起只允许数字。
    static let roomCodeLength = 4

    /// 房号规范化：只保留数字并截到 4 位。
    /// 用户手输的 `4 8 2 1` / `4821abc` 都归一成 `4821`。
    static func normalizeRoomCode(_ text: String) -> String {
        String(text.filter { $0.isNumber }.prefix(roomCodeLength))
    }

    static let maxFrame = 65536

    /// 断线宽限：宽限期内时钟暂停，到点判负。
    static let reconnectGraceMs = 120_000
    /// 链路静默判定
    static let hostIdleMs = 13_000
    static let guestIdleMs = 15_000
    static let hostPingMs = 5_000
    static let guestReconnectMs = 1_500
    /// 房主等待首帧（hello / probe）的超时，与 Android `LanHost` 的 3 秒一致
    static let hostFirstFrameMs = 3_000
    /// 发现探活
    static let probeTimeoutMs = 1_500
    static let probeFirstTimeoutMs = 1_200
    static let probeIntervalMs = 3_500
    static let probeTtlMs = 15_000
    static let newEntryGraceMs = 6_000

    /// 棋盘规模
    static let goSize = 19
    static let goKomi = 7.5

    static let goGame = "go"
    static let xiangqiGame = "xiangqi"
    static let gomokuGame = "gomoku"
    static let banqiGame = "banqi"

    /// 未知/空值一律回落围棋；其余三种原样保留。
    static func normalizedGame(_ raw: String) -> String {
        switch raw {
        case goGame, xiangqiGame, gomokuGame, banqiGame: return raw
        default: return goGame
        }
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// 单调时钟毫秒，用于链路/计时，不受系统时间调整影响
    static func uptimeMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    // MARK: - 信封

    static func message(_ type: String, room: String, from: String,
                        payload: [String: Any] = [:]) -> [String: Any] {
        [
            "v": version,
            "t": type,
            "sid": newSessionId(),
            "ts": nowMs(),
            "seq": 0,
            "room": room,
            "from": from,
            "p": payload
        ]
    }

    static func type(_ msg: [String: Any]?) -> String {
        guard let msg else { return "" }
        return string(msg, "t")
    }

    static func payload(_ msg: [String: Any]?) -> [String: Any] {
        guard let p = msg?["p"] as? [String: Any] else { return [:] }
        return p
    }

    static func newSessionId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    /// 4 位纯数字房号（旧版含字母的房号不再生成）。
    static func newRoomCode() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    /// 注册实例 ID：每次注册新生成 8 位，用于同一房间码去重。
    static func newInstanceId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    // MARK: - 取值（JSONSerialization 会把数字解析成 NSNumber）

    static func string(_ dict: [String: Any], _ key: String, _ def: String = "") -> String {
        guard let v = dict[key] else { return def }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return def
    }

    static func int(_ dict: [String: Any], _ key: String, _ def: Int = 0) -> Int {
        guard let v = dict[key] else { return def }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
        return def
    }

    static func int64(_ dict: [String: Any], _ key: String, _ def: Int64 = 0) -> Int64 {
        guard let v = dict[key] else { return def }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let n = Int64(s.trimmingCharacters(in: .whitespaces)) { return n }
        return def
    }

    static func double(_ dict: [String: Any], _ key: String, _ def: Double = 0) -> Double {
        guard let v = dict[key] else { return def }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let n = Double(s.trimmingCharacters(in: .whitespaces)) { return n }
        return def
    }

    static func bool(_ dict: [String: Any], _ key: String, _ def: Bool = false) -> Bool {
        guard let v = dict[key] else { return def }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s == "true" || s == "1" }
        return def
    }

    static func array(_ dict: [String: Any], _ key: String) -> [[String: Any]] {
        (dict[key] as? [[String: Any]]) ?? []
    }

    // MARK: - 颜色

    /// 座位/颜色整数：1=黑(围棋/五子棋)/红(象棋)/先手(暗棋)，2=白/黑/后手
    static func colorChar(game: String, seat: Int) -> String {
        if game == banqiGame { return seat == 1 ? "1" : "2" }
        if game == goGame || game == gomokuGame { return seat == 1 ? "B" : "W" }
        return seat == 1 ? "R" : "B"
    }

    static func seatOfColorChar(game: String, _ text: String) -> Int? {
        let t = text.uppercased()
        if game == banqiGame {
            if t == "1" { return 1 }
            if t == "2" { return 2 }
            // 兼容旧字段：B 当作先手，W 当作后手
            if t == "B" { return 1 }
            if t == "W" { return 2 }
            return nil
        }
        if game == goGame || game == gomokuGame {
            if t == "B" { return 1 }
            if t == "W" { return 2 }
            return nil
        }
        if t == "R" { return 1 }
        if t == "B" { return 2 }
        return nil
    }

    /// 围棋用：黑/白
    static func goColorName(_ color: Int) -> String { color == 1 ? "黑" : "白" }

    /// 象棋用：红/黑
    static func xqColorName(_ color: Int) -> String { color == 1 ? "红" : "黑" }

    static func gameName(_ game: String) -> String {
        switch game {
        case xiangqiGame: return "象棋"
        case gomokuGame: return "五子棋"
        case banqiGame: return "暗棋"
        default: return "围棋"
        }
    }

    // MARK: - TXT 记录

    /// Bonjour TXT 记录编码：每项为 1 字节长度 + UTF-8 的 key=value。
    static func txtData(_ dict: [String: String]) -> Data {
        var out = Data()
        for key in dict.keys.sorted() {
            guard let value = dict[key] else { continue }
            let entry = Array("\(key)=\(value)".utf8)
            guard entry.count <= 255 else { continue }
            out.append(UInt8(entry.count))
            out.append(contentsOf: entry)
        }
        return out
    }

    // MARK: - 本机地址

    /// 取本机用于局域网通信的 IPv4。
    ///
    /// 之前只排除 lo0，装了 VPN（utun）/ 开了热点（bridge）时可能把虚拟网卡的地址
    /// 写进 TXT 和 UDP 应答，安卓按那个地址连过来必然失败。现在显式跳过虚拟网卡，
    /// 优先 en0（Wi-Fi），并把最终选中的网卡名打进日志，便于取证。
    static func localIPv4Address() -> String {
        var fallback = ("", "")
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "" }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name != "lo0", !isVirtualInterface(name) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    var sockAddr = addr.pointee
                    let result = getnameinfo(&sockAddr, socklen_t(sockAddr.sa_len),
                                             &host, socklen_t(host.count),
                                             nil, 0, NI_NUMERICHOST)
                    if result == 0 {
                        let ip = String(cString: host)
                        if name == "en0" || name == "en1" {
                            NSLog("[LanProto] 本机地址 if=%@ ip=%@", name, ip)
                            return ip
                        }
                        if fallback.0.isEmpty { fallback = (ip, name) }
                    }
                }
            }
            pointer = interface.ifa_next
        }
        NSLog("[LanProto] 本机地址（回退）if=%@ ip=%@", fallback.1, fallback.0)
        return fallback.0
    }

    /// 虚拟网卡（VPN / 热点 / P2P / 蜂窝）不能作为房间地址公布给对端。
    private static func isVirtualInterface(_ name: String) -> Bool {
        let prefixes = ["utun", "ipsec", "ppp", "tun", "tap",
                        "awdl", "llw", "bridge", "vmenet", "anpi", "pdp_ip"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// 子网定向广播地址（配合 255.255.255.255 一起发，部分路由器只放行其中一种）。
    static func broadcastAddresses() -> [String] {
        var out = ["255.255.255.255"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let addr = interface.ifa_addr, let mask = interface.ifa_netmask,
               addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name != "lo0" {
                    let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                    let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                    let broadcast = ip | ~netmask
                    if broadcast != 0 {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        var sa = sockaddr_in()
                        sa.sin_family = sa_family_t(AF_INET)
                        sa.sin_addr.s_addr = broadcast
                        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                        let result = withUnsafePointer(to: &sa) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                            }
                        }
                        if result == 0 {
                            let text = String(cString: host)
                            if !text.isEmpty, !out.contains(text) { out.append(text) }
                        }
                    }
                }
            }
            pointer = interface.ifa_next
        }
        return out
    }

    // MARK: - 摘要
    /// 与 Android 一致的 SHA-256 十六进制（小写）。
    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 象棋 hash：SHA-256 后取前 8 字节（16 字符）
    static func sha256Prefix8(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// 消息类型。与 Android `Proto` 的常量逐字一致。
enum LanMsg {
    static let hello = "hello"
    static let helloAck = "hello_ack"
    static let helloReject = "hello_reject"
    static let lobby = "lobby"
    static let ready = "ready"
    static let gameStart = "game_start"
    static let move = "move"
    static let moveAck = "move_ack"
    static let moveReject = "move_reject"
    static let snapshot = "state_snapshot"
    static let syncRequest = "sync_request"
    static let undoRequest = "undo_request"
    static let undoResponse = "undo_response"
    static let undoApplied = "undo_applied"
    static let resign = "resign"
    static let drawOffer = "draw_offer"
    static let drawResponse = "draw_response"
    static let clock = "clock"
    static let ping = "ping"
    static let pong = "pong"
    static let probe = "probe"
    static let probeAck = "probe_ack"
    static let gameOver = "game_over"
    /// 双方连续各停一手后进入「数子待确认」，由房主确认后才发 game_over
    static let scorePending = "score_pending"
    static let bye = "bye"

    static let eGameMismatch = "E_GAME_MISMATCH"
    static let eRoomFull = "E_ROOM_FULL"
    static let eBadRoom = "E_BAD_ROOM"
    static let eVersion = "E_VERSION"
}

/// UDP 发现报文（41235）的类型名与兼容别名。
///
/// 以全小写 + 下划线为准；解析时先归一化（去空白、去下划线/连字符、转小写），
/// 因此 `room_reply` / `roomReply` / `reply` 都认。Android 侧 `Proto.udpKind()` 用同一套规则，
/// 两端字段表见 `fieldTable`。
enum LanUdpTypes {
    static let query = "room_query"
    static let reply = "room_reply"
    static let announce = "room_announce"

    static func kind(_ raw: Any?) -> String {
        guard let s = raw as? String else { return "" }
        let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch k {
        case "roomquery", "query": return query
        case "roomreply", "reply": return reply
        case "roomannounce", "announce": return announce
        default: return k
        }
    }

    /// 两端字段对照（诊断区直接展示，方便逐个字符比对）
    static let fieldTable = "t:String(room_query|room_reply|room_announce) "
        + "room:String(4位数字) game:String(go|xiangqi|gomoku|banqi) port:Int size:String(19|9) "
        + "addr:String iid:String name:String v:Int"

    /// 房主广播 / 应答的唯一构造入口。
    /// `kind` 只允许传 `announce` 或 `reply`：房主绝不会构造 `room_query`。
    static func hostAnswerPayload(_ kind: String,
                                  room: String,
                                  game: String,
                                  port: UInt16,
                                  addr: String,
                                  iid: String,
                                  size: String,
                                  name: String) -> [String: Any] {
        precondition(kind == announce || kind == reply, "房主只能发 announce / reply，不能发 \(kind)")
        return [
            "t": kind,
            "room": room,
            "game": game,
            "port": Int(port),
            "addr": addr,
            "iid": iid,
            "pid": iid,
            "size": size,
            "name": name,
            "ts": LanProto.nowMs(),
            "v": LanProto.version
        ]
    }

    /// 启动自检：把「谁该发什么、字段是否齐全」变成可断言的事实。
    /// 结果会写进诊断区与日志时间线。
    static func selfCheck() -> [String] {
        var lines: [String] = []
        let a = hostAnswerPayload(announce, room: "4821", game: LanProto.goGame,
                                  port: 41234, addr: "192.168.1.2",
                                  iid: "ABCD1234", size: "19", name: "iPhone")
        let r = hostAnswerPayload(reply, room: "4821", game: LanProto.xiangqiGame,
                                  port: 41234, addr: "192.168.1.2",
                                  iid: "ABCD1234", size: "9", name: "iPhone")
        assert(a["t"] as? String == announce)
        assert(r["t"] as? String == reply)
        assert((a["room"] as? String)?.count == 4)
        assert((a["game"] as? String) == LanProto.goGame || (a["game"] as? String) == LanProto.xiangqiGame)
        assert((a["port"] as? Int ?? 0) > 0)
        assert((a["iid"] as? String)?.isEmpty == false)
        assert((a["addr"] as? String)?.isEmpty == false)
        lines.append("房主通告 t=\(a["t"] ?? "") room=\(a["room"] ?? "") game=\(a["game"] ?? "") port=\(a["port"] ?? 0) ✓")
        lines.append("房主应答 t=\(r["t"] ?? "") 字段数=\(r.count) ✓")
        lines.append("客机查询 t=\(query) 只由 LanUdpDiscovery 发送 ✓")
        lines.append("别名：room_reply|roomReply|reply、room_announce|roomAnnounce|announce 均接受 ✓")
        return lines
    }
}

/// 结果中文文案，映射规则与 Android `ResultText` 保持一致。仅用于展示。
enum LanResultText {
    static func text(gameId: String, code: String, reason: String, detail: String) -> String {
        let c = code.trimmingCharacters(in: .whitespaces)
        let r = reason.trimmingCharacters(in: .whitespaces)
        let d = detail.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return d.isEmpty ? "对局结束" : d }
        if gameId == LanProto.gomokuGame { return gomokuResult(code: c.uppercased(), reason: r, detail: d) }
        if gameId == LanProto.banqiGame { return banqiResult(code: c.lowercased(), reason: r, detail: d) }
        let xiangqi = gameId == LanProto.xiangqiGame
        if c.lowercased() == "draw" { return xiangqi ? xiangqiDraw(d) : "和棋" }
        return xiangqi ? xiangqiWin(code: c.uppercased(), reason: r, detail: d)
                       : goResult(code: c.uppercased(), reason: r, detail: d)
    }

    /// 五子棋：B/W + "+5" / "+R" / "+T"（与 Android GomokuRules 一致）
    private static func gomokuResult(code: String, reason: String, detail: String) -> String {
        if code.lowercased() == "draw" { return detail.isEmpty ? "和棋" : detail }
        guard let flag = code.first, flag == "B" || flag == "W" else {
            return detail.isEmpty ? "对局结束" : detail
        }
        let winner = flag == "B" ? "黑方" : "白方"
        let loser = flag == "B" ? "白方" : "黑方"
        switch reason.lowercased() {
        case "resign": return "\(winner)胜（\(loser)认输）"
        case "timeout": return "\(winner)胜（\(loser)超时判负）"
        case "disconnect": return "\(winner)胜（\(loser)断线判负）"
        default: break
        }
        let tag = String(code.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if tag.uppercased() == "R" { return "\(winner)胜（\(loser)认输）" }
        if tag.uppercased() == "T" { return "\(winner)胜（\(loser)超时判负）" }
        if !detail.isEmpty { return detail }
        return "\(winner)五连获胜"
    }

    /// 暗棋：red / black / draw，文案优先用终局原因（认输/超时/断线/无子可动）
    private static func banqiResult(code: String, reason: String, detail: String) -> String {
        if code == "draw" { return detail.isEmpty ? "和棋" : detail }
        guard code == "red" || code == "black" else {
            return detail.isEmpty ? "对局结束" : detail
        }
        let winner = code == "red" ? "红方" : "黑方"
        let loser = code == "red" ? "黑方" : "红方"
        switch reason.lowercased() {
        case "resign": return "\(winner)胜（\(loser)认输）"
        case "timeout": return "\(winner)胜（\(loser)超时判负）"
        case "disconnect": return "\(winner)胜（\(loser)断线判负）"
        default: break
        }
        return detail.isEmpty ? "\(winner)胜" : detail
    }

    static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "resign": return "中盘认输"
        case "timeout": return "超时判负"
        case "disconnect": return "断线判负"
        case "score": return "数子结果"
        case "rule": return "规则判定"
        case "draw": return "和棋"
        default: return ""
        }
    }

    private static func goResult(code: String, reason: String, detail: String) -> String {
        guard code.count > 2, let flag = code.first, flag == "B" || flag == "W", code.dropFirst().first == "+" else {
            return detail.isEmpty ? "对局结束" : detail
        }
        let blackWin = flag == "B"
        let winner = blackWin ? "黑方" : "白方"
        let loser = blackWin ? "白方" : "黑方"
        let tag = String(code.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if reason.lowercased() == "disconnect" { return "\(winner)胜（\(loser)断线判负）" }
        if tag.uppercased() == "R" { return "\(winner)中盘胜（\(loser)认输）" }
        if tag.uppercased() == "T" { return "\(winner)胜（\(loser)超时判负）" }
        if isNumber(tag) { return "\(winner)胜 \(tag) 目" }
        return "\(winner)胜（\(tag.isEmpty ? "数目" : tag)）"
    }

    private static func xiangqiWin(code: String, reason: String, detail: String) -> String {
        let redWin = code.hasPrefix("R")
        let winner = redWin ? "红方" : "黑方"
        let loser = redWin ? "黑方" : "红方"
        switch reason.lowercased() {
        case "resign": return "\(winner)胜（\(loser)认输）"
        case "timeout": return "\(winner)胜（\(loser)超时判负）"
        case "disconnect": return "\(winner)胜（\(loser)断线判负）"
        default: break
        }
        if detail.contains("被将死") { return "\(winner)胜（\(loser)被将死）" }
        if detail.contains("困毙") { return "\(winner)胜（\(loser)困毙，无子可走）" }
        if detail.contains("长将") { return "\(winner)胜（\(loser)长将判负）" }
        return "\(winner)胜"
    }

    private static func xiangqiDraw(_ detail: String) -> String {
        if detail.contains("六十回合") || detail.contains("60 回合") { return "和棋（六十回合无吃子）" }
        if detail.contains("重复") { return "和棋（三次重复局面）" }
        if detail.contains("协议") { return "和棋（双方协议）" }
        return "和棋"
    }

    private static func isNumber(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var dot = false
        for ch in s {
            if ch == ".", !dot { dot = true; continue }
            if ch < "0" || ch > "9" { return false }
        }
        return true
    }
}
