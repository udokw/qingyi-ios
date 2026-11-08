import Foundation
import Network

/// 一条可连接的房间记录。
struct LanRoom: Identifiable {
    let name: String          // QY-XXXX-19
    let code: String          // XXXX
    let size: String          // 19
    let game: String          // go / xiangqi
    let host: String          // TXT addr（IPv4）
    let port: UInt16          // TXT port
    let pid: Int
    let iid: String
    let ts: Int64

    var foundAt: Int64
    var lastProbeAt: Int64
    var lastOkAt: Int64
    var verified: Bool
    var probing: Bool
    /// 由 UDP 广播通告/应答发现的房间：只按 UDP 刷新过期，不因 TCP 探活失败被删
    var fromUdp: Bool = false

    var id: String { iid.isEmpty ? name : iid }

    var boardText: String { game == LanProto.xiangqiGame ? "9 × 10" : "\(size) 路" }
    var gameLabel: String { LanProto.gameName(game) }
}

/// mDNS/DNS-SD 发现：同时浏览统一类型与棋种专用类型，按 iid 去重，并做房间级探活。
final class LanDiscovery {
    var onRooms: (([LanRoom]) -> Void)?
    var onError: ((String) -> Void)?
    /// 是否只保留与指定棋种一致的房间；nil 表示全部
    var gameFilter: String?

    private let queue = DispatchQueue(label: "qingyi.lan.browse")
    private var browsers: [NWBrowser] = []
    private var timer: DispatchSourceTimer?
    private var rooms: [String: LanRoom] = [:]
    private var running = false

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            NSLog("[mDNS] 开始浏览 %@", LanProto.allServiceTypesNW.joined(separator: ","))
            for type in LanProto.allServiceTypesNW {
                let params = NWParameters.tcp
                let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
                browser.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        NSLog("[mDNS] %@ 浏览就绪", type)
                    case .failed(let error):
                        NSLog("[mDNS] %@ 浏览失败：%@", type, error.localizedDescription)
                        self?.onError?("搜索失败：\(error.localizedDescription)，请使用手动 IP")
                    case .waiting(let error):
                        NSLog("[mDNS] %@ 等待中：%@", type, error.localizedDescription)
                    case .cancelled:
                        NSLog("[mDNS] %@ 已取消", type)
                    default:
                        break
                    }
                }
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    NSLog("[mDNS] %@ 结果数 \(results.count)", type)
                    self?.handle(results)
                }
                browser.start(queue: self.queue)
                self.browsers.append(browser)
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.8, repeating: 0.8)
            timer.setEventHandler { [weak self] in self?.sweep() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            for browser in self.browsers { browser.cancel() }
            self.browsers.removeAll()
            self.rooms.removeAll()
            self.onRooms?([])
        }
    }

    // MARK: - 发现

    private func handle(_ results: Set<NWBrowser.Result>) {
        let now = LanProto.uptimeMs()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            guard name.hasPrefix("QY-") else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                txt = record.dictionary
            }
            let iid = txt["iid"] ?? ""
            let key = iid.isEmpty ? name : iid

            if rooms[key] != nil { continue }

            let parts = name.split(separator: "-", omittingEmptySubsequences: false)
            let code = txt["room"] ?? (parts.count >= 2 ? String(parts[1]) : "")
            let size = txt["size"] ?? (parts.count >= 3 ? leadingDigits(String(parts[2])) : "19")
            let game = (txt["game"].flatMap { $0.isEmpty ? nil : $0 }) ?? LanProto.goGame
            let host = (txt["addr"] ?? "").trimmingCharacters(in: .whitespaces)
            let portValue = Int(txt["port"] ?? "") ?? 0
            NSLog("[mDNS] 解析 \(name) room=\(code) addr=\(host.isEmpty ? "(空)" : host) port=\(portValue) game=\(game) txt=\(txt.keys.sorted().joined(separator: ","))")
            guard !code.isEmpty, !host.isEmpty, portValue > 0, portValue < 65536,
                  let port = UInt16(exactly: portValue) else {
                // TXT 里没有 addr（或端口缺失）时旧版直接丢弃，房间永远不出现。
                // 现在交给 UDP 通告/查询通道补全真实地址，不再静默丢弃。
                NSLog("[mDNS] 丢弃 %@：TXT 缺 addr/port，等待 UDP 通道补全", name)
                continue
            }

            let room = LanRoom(name: name,
                               code: code,
                               size: size,
                               game: game,
                               host: host,
                               port: port,
                               pid: Int(txt["pid"] ?? "") ?? 0,
                               iid: iid,
                               ts: Int64(txt["ts"] ?? "") ?? 0,
                               foundAt: now,
                               lastProbeAt: 0,
                               lastOkAt: 0,
                               verified: false,
                               probing: false)
            rooms[key] = room
            probe(key)
        }
        publish()
    }

    /// 把 UDP 通告/应答发现的房间并入同一个列表（去重键优先 iid）。
    /// UDP 包来自房主本机，源地址即真实 IPv4，因此直接视为可用，不再等 TCP 探活。
    func ingest(_ incoming: [LanRoom]) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            let now = LanProto.uptimeMs()
            for var room in incoming {
                if let filter = self.gameFilter, room.game != filter { continue }
                room.fromUdp = true
                room.verified = true
                room.probing = false
                room.lastOkAt = now
                room.lastProbeAt = now
                let key = room.iid.isEmpty ? "\(room.code)@\(room.host):\(room.port)" : room.iid
                self.rooms[key] = room
            }
            self.publish()
        }
    }

    private func sweep() {
        guard running else { return }
        let now = LanProto.uptimeMs()
        var removed = false
        for (key, room) in rooms {
            // UDP 通道发现的房间：不跑 TCP 探活，只按 UDP 刷新时间过期
            if room.fromUdp {
                if now - room.lastOkAt > 8_000 {
                    rooms.removeValue(forKey: key)
                    removed = true
                }
                continue
            }
            if room.verified {
                if now - room.lastOkAt > LanProto.probeTtlMs {
                    rooms.removeValue(forKey: key)
                    removed = true
                    continue
                }
            } else if now - room.foundAt > LanProto.newEntryGraceMs {
                rooms.removeValue(forKey: key)
                removed = true
                continue
            }
            if !room.probing, now - room.lastProbeAt >= LanProto.probeIntervalMs {
                probe(key)
            }
        }
        if removed { publish() }
    }

    // MARK: - 探活

    private func probe(_ key: String) {
        guard var room = rooms[key] else { return }
        let started = LanProto.uptimeMs()
        room.probing = true
        room.lastProbeAt = started
        rooms[key] = room

        LanProber().run(host: room.host, port: room.port, room: room.code,
                        timeoutMs: room.verified ? LanProto.probeTimeoutMs : LanProto.probeFirstTimeoutMs) { [weak self] result in
            self?.queue.async {
                guard let self, var current = self.rooms[key] else { return }
                switch result {
                case LanProber.alive:
                    NSLog("[探活] \(current.code) \(current.host):\(current.port) 存活")
                    current.verified = true
                    current.probing = false
                    current.lastOkAt = LanProto.uptimeMs()
                    self.rooms[key] = current
                case LanProber.unknown:
                    current.probing = false
                    self.rooms[key] = current
                default:
                    NSLog("[探活] \(current.code) \(current.host):\(current.port) 结果 \(result)，移除")
                    self.rooms.removeValue(forKey: key)
                }
                self.publish()
            }
        }
    }

    private func publish() {
        let filter = gameFilter
        let list = rooms.values
            .filter { filter == nil || $0.game == filter }
            .sorted { lhs, rhs in
                if lhs.verified != rhs.verified { return lhs.verified }
                if lhs.ts != rhs.ts { return lhs.ts > rhs.ts }
                return lhs.name < rhs.name
            }
        let snapshot = Array(list)
        DispatchQueue.main.async { [weak self] in
            self?.onRooms?(snapshot)
        }
    }

    private func leadingDigits(_ s: String) -> String {
        var out = ""
        for ch in s {
            guard ch.isNumber else { break }
            out.append(ch)
        }
        return out.isEmpty ? "19" : out
    }
}

/// 房间级探活：连接后发 probe，房主回 probe_ack 并带上自己的房间码。
/// 只做 TCP 连接判断不够——房主重启后新旧房间常复用同一端口，
/// 旧 mDNS 条目会因此「看起来还活着」，点进去才报房间码不对。
final class LanProber {
    static let dead = 0
    static let alive = 1
    static let unknown = 2
    static let stale = -1

    private let queue = DispatchQueue(label: "qingyi.lan.probe")
    private var connection: NWConnection?
    private var timeoutItem: DispatchWorkItem?
    private var buffer = Data()
    private var done = false
    /// 探活对象由调用方临时创建，这里自持一份直到结束，否则会在等待回包时被释放。
    private var strongSelf: LanProber?

    func run(host: String, port: UInt16, room: String, timeoutMs: Int,
             completion: @escaping (Int) -> Void) {
        strongSelf = self
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            strongSelf = nil
            completion(LanProber.dead)
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(trimmed), port: nwPort, using: .tcp)
        connection = conn

        let item = DispatchWorkItem { [weak self] in self?.finish(LanProber.unknown, completion) }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + Double(max(400, timeoutMs)) / 1000, execute: item)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let msg = LanProto.message(LanMsg.probe, room: room, from: "guest")
                if let frame = try? LanFrame.encode(msg) {
                    conn.send(content: frame, completion: .contentProcessed { _ in })
                }
                self?.receive(conn, room: room, completion: completion)
            case .failed:
                self?.finish(LanProber.dead, completion)
            case .cancelled:
                self?.finish(LanProber.unknown, completion)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, room: String, completion: @escaping (Int) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: LanProto.maxFrame) { [weak self] data, _, isComplete, error in
            guard let self, !self.done else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let msg = try? LanFrame.decode(&self.buffer) {
                    let type = LanProto.type(msg)
                    let actual = LanProto.string(LanProto.payload(msg), "room")
                    if type == LanMsg.probeAck, !actual.isEmpty {
                        self.finish(actual.caseInsensitiveCompare(room) == .orderedSame
                                    ? LanProber.alive : LanProber.stale, completion)
                        return
                    }
                    self.finish(LanProber.unknown, completion)
                    return
                }
            }
            if error != nil || isComplete {
                self.finish(LanProber.unknown, completion)
                return
            }
            self.receive(conn, room: room, completion: completion)
        }
    }

    private func finish(_ result: Int, _ completion: @escaping (Int) -> Void) {
        guard !done else { return }
        done = true
        timeoutItem?.cancel()
        timeoutItem = nil
        connection?.cancel()
        connection = nil
        strongSelf = nil
        completion(result)
    }
}
