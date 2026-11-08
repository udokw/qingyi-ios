import Foundation
import Network

/// 「只填房号」加入时的兜底发现：UDP 广播按房号定向查询。
/// mDNS 被路由器/热点过滤时，UDP 广播通常仍然可用；
/// 房主的真实 TCP 端口写在应答里，因此客户端不需要假设任何端口区间。
enum LanRoomQuery {
    /// 广播查询房号，返回 `["192.168.1.5:54321", ...]`。
    static func lookup(code: String, timeout: TimeInterval = 2.0) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: lookupSync(code: code, timeout: timeout))
            }
        }
    }

    private static func lookupSync(code: String, timeout: TimeInterval) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 120_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload: [String: Any] = [
            "t": LanProto.roomQueryType,
            "room": code,
            "v": LanProto.version
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return [] }

        for host in LanProto.broadcastAddresses() {
            send(fd, data, to: host)
        }

        var result: [String] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        var lastSend = Date.distantPast
        while Date() < deadline {
            // 广播 UDP 可能被丢弃：每 400ms 重发一次查询
            if Date().timeIntervalSince(lastSend) > 0.4 {
                for host in LanProto.broadcastAddresses() { send(fd, data, to: host) }
                lastSend = Date()
            }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: Int = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, raw.baseAddress, raw.count, 0, sa, &len)
                    }
                }
            }
            if n <= 0 { continue }
            let body = Data(buffer[0..<n])
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  (obj["t"] as? String) == LanProto.roomReplyType else { continue }
            let room = LanProto.normalizeRoomCode(obj["room"] as? String ?? "")
            guard room == code else { continue }
            // 应答包的源地址就是房主在本网段的真实地址，比 TXT 里的 addr 更可靠
            let source = string(from.sin_addr)
            var addr = (obj["addr"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !source.isEmpty { addr = source }
            guard let port = obj["port"] as? Int, port > 0, port < 65536, !addr.isEmpty else { continue }
            let endpoint = "\(addr):\(port)"
            if !result.contains(endpoint) { result.append(endpoint) }
        }
        return result
    }

    private static func string(_ addr: in_addr) -> String {
        var value = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &value, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buf)
    }

    private static func send(_ fd: Int32, _ data: Data, to host: String) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = LanProto.queryPort.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return }
        data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

/// 房主侧 UDP 应答器：收到 `room_query` 且房号匹配时，回一条带真实 TCP 端口的 `room_reply`。
/// 端口由系统分配时客户端也能从应答里拿到，不依赖固定区间。
final class LanQueryResponder {
    private let queue = DispatchQueue(label: "qingyi.lan.query")
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private var room: String
    private var game: String
    private var iid: String
    private var port: UInt16 = 0
    private var addr = ""

    init(room: String, game: String, iid: String) {
        self.room = room
        self.game = game
        self.iid = iid
    }

    func update(port: UInt16, addr: String) {
        lock.lock()
        self.port = port
        self.addr = addr
        lock.unlock()
    }

    /// 用 BSD UDP socket 直接监听 41235。之前用 NWListener(.udp) 在本机实测会进入
    /// EINVAL(22) 且没有日志，房号查询因此静默失效；BSD socket 行为可预测、错误码可打印。
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.running { self.lock.unlock(); return }
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            guard s >= 0 else {
                let e = errno
                NSLog("[LanQuery] socket() 失败 POSIX \(e) \(String(cString: strerror(e)))")
                self.lock.unlock()
                return
            }
            var on: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = LanProto.queryPort.bigEndian
            a.sin_addr.s_addr = 0
            let bound = withUnsafePointer(to: &a) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                let e = errno
                NSLog("[LanQuery] bind \(LanProto.queryPort) 失败 POSIX \(e) \(String(cString: strerror(e)))")
                close(s)
                self.lock.unlock()
                return
            }
            self.fd = s
            self.running = true
            self.lock.unlock()
            NSLog("[LanQuery] UDP 应答器已监听 %d", Int(LanProto.queryPort))

            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                self.lock.lock()
                let alive = self.running
                self.lock.unlock()
                if !alive { break }
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n: Int = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &from) { fp in
                        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            recvfrom(s, raw.baseAddress, raw.count, 0, sa, &len)
                        }
                    }
                }
                if n <= 0 { continue }
                let body = Data(buffer[0..<n])
                guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      (obj["t"] as? String) == LanProto.roomQueryType else { continue }

                self.lock.lock()
                let room = self.room, game = self.game, iid = self.iid
                let port = self.port, addr = self.addr
                self.lock.unlock()
                let requested = LanProto.normalizeRoomCode(obj["room"] as? String ?? "")
                guard requested == room, port > 0 else { continue }

                let reply: [String: Any] = [
                    "t": LanProto.roomReplyType,
                    "room": room,
                    "game": game,
                    "port": Int(port),
                    "addr": addr,
                    "iid": iid,
                    "v": LanProto.version
                ]
                guard let out = try? JSONSerialization.data(withJSONObject: reply) else { continue }
                _ = out.withUnsafeBytes { raw in
                    withUnsafePointer(to: &from) { fp in
                        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(s, raw.baseAddress, raw.count, 0, sa, len)
                        }
                    }
                }
            }
            close(s)
        }
    }

    func stop() {
        lock.lock()
        running = false
        let s = fd
        fd = -1
        lock.unlock()
        // 只 shutdown 唤醒阻塞中的 recvfrom，真正的 close 由读取循环退出时执行，避免 double close
        if s >= 0 { shutdown(s, SHUT_RDWR) }
    }
}

/// App 内端口自检：用 BSD bind 直接问内核，把 errno 原样输出。
/// 上一版用 NWListener 做探针，14 个端口全部返回 POSIX 22(EINVAL)，
/// 那是 Network.framework 的监听器状态问题，不是端口真实可用性。
enum LanPortProbe {
    static func report(timeout: TimeInterval = 0.8) async -> String {
        var lines: [String] = []
        let ip = LanProto.localIPv4Address()
        lines.append("本机 IPv4：\(ip.isEmpty ? "未取到（可能没有 Wi-Fi）" : ip)")
        let ports: [UInt16] = [0] + LanProto.portCandidates + [49152, 55555]
        var okCount = 0
        for port in ports {
            let result = probe(port: port)
            if result.ok { okCount += 1 }
            lines.append("\(port == 0 ? "系统分配" : "\(port)")：\(result.text)")
        }
        lines.append("可用 \(okCount)/\(ports.count)（TCP bind 实测）")
        lines.append("说明：bind 成功只代表内核允许占用该端口；能否被同网段访问还取决于 Wi-Fi 与本地网络权限。")
        return lines.joined(separator: "\n")
    }

    /// 直接 bind 0.0.0.0:port 后立刻关闭；不设置 SO_REUSEADDR，确保能暴露“已被占用”。
    private static func probe(port: UInt16) -> (ok: Bool, text: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let e = errno
            return (false, "socket() POSIX \(e) \(String(cString: strerror(e)))")
        }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let e = errno
            return (false, "POSIX \(e) \(String(cString: strerror(e)))")
        }
        var actual = addr
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return (true, "可监听（实际端口 \(UInt16(bigEndian: actual.sin_port))）")
    }
}

