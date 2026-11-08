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
        while Date() < deadline {
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
            let addr = (obj["addr"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let port = obj["port"] as? Int, port > 0, port < 65536, !addr.isEmpty else { continue }
            let endpoint = "\(addr):\(port)"
            if !result.contains(endpoint) { result.append(endpoint) }
        }
        return result
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
    private var listener: NWListener?
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

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil,
                  let nwPort = NWEndpoint.Port(rawValue: LanProto.queryPort) else { return }
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params, on: nwPort) else { return }
            l.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            l.start(queue: self.queue)
            self.listener = l
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receiveMessage { [weak self, weak connection] data, _, _, _ in
            guard let self, let connection else { return }
            defer { connection.cancel() }
            guard let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (obj["t"] as? String) == LanProto.roomQueryType else { return }

            self.lock.lock()
            let room = self.room, game = self.game, iid = self.iid
            let port = self.port, addr = self.addr
            self.lock.unlock()

            let requested = LanProto.normalizeRoomCode(obj["room"] as? String ?? "")
            guard requested == room, port > 0 else { return }

            let reply: [String: Any] = [
                "t": LanProto.roomReplyType,
                "room": room,
                "game": game,
                "port": Int(port),
                "addr": addr,
                "iid": iid,
                "v": LanProto.version
            ]
            guard let out = try? JSONSerialization.data(withJSONObject: reply) else { return }
            connection.send(content: out, completion: .contentProcessed { _ in })
        }
    }
}

/// App 内端口自检：逐个尝试真实 bind，把 NWError 原样输出。
/// 「11 个端口都被占用」这种结论必须靠实测数据判断，而不是猜。
enum LanPortProbe {
    static func report(timeout: TimeInterval = 0.8) async -> String {
        var lines: [String] = []
        let ip = LanProto.localIPv4Address()
        lines.append("本机 IPv4：\(ip.isEmpty ? "未取到（可能没有 Wi-Fi）" : ip)")
        let ports: [UInt16] = [0] + LanProto.portCandidates + [49152, 55555]
        var okCount = 0
        for port in ports {
            let result = await probe(port: port, timeout: timeout)
            if result.ok { okCount += 1 }
            lines.append("\(port == 0 ? "系统分配" : "\(port)")：\(result.text)")
        }
        lines.append("可用 \(okCount)/\(ports.count)（TCP / NWListener）")
        return lines.joined(separator: "\n")
    }

    private static func probe(port: UInt16, timeout: TimeInterval) async -> (ok: Bool, text: String) {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "qingyi.portprobe")
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let endpoint: NWEndpoint.Port
            if port == 0 {
                endpoint = .any
            } else if let value = NWEndpoint.Port(rawValue: port) {
                endpoint = value
            } else {
                continuation.resume(returning: (false, "端口值非法"))
                return
            }
            guard let listener = try? NWListener(using: params, on: endpoint) else {
                continuation.resume(returning: (false, "NWListener 创建失败"))
                return
            }
            var finished = false
            listener.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    let actual = listener.port?.rawValue ?? 0
                    listener.cancel()
                    continuation.resume(returning: (true, "可监听（实际端口 \(actual)）"))
                case .failed(let error):
                    finished = true
                    listener.cancel()
                    continuation.resume(returning: (false, describe(error)))
                case .waiting(let error):
                    // waiting 说明 bind 暂时被拒；交给超时兜底，同时保留错误码
                    print("[PortProbe] \(port) waiting: \(describe(error))")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !finished else { return }
                finished = true
                listener.cancel()
                continuation.resume(returning: (false, "超时未 ready"))
            }
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "POSIX \(code.rawValue) \(String(cString: strerror(code.rawValue)))"
        case .dns(let code):
            return "DNS \(code)"
        case .tls(let status):
            return "TLS \(status)"
        @unknown default:
            return "\(error)"
        }
    }
}

