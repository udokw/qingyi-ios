import Foundation
import Network

/// 局域网房主：监听端口 + 发布 Bonjour + 处理 probe + 维持单个客机连接。
/// 进入对局后不注销公告、不停监听，断线客机可在宽限期内重连。
final class LanHost {
    let roomCode: String
    let gameId: String
    let size: Int
    let iid = LanProto.newInstanceId()
    let pid = Int(ProcessInfo.processInfo.processIdentifier)

    var onReady: ((UInt16, String) -> Void)?
    var onError: ((String) -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onGuestChanged: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "qingyi.lan.host")
    private var listener: NWListener?
    private var netServices: [NetService] = []
    private var port: UInt16 = 0
    private var addr = ""
    private var guest: LanConnection?
    private var guestHandshaked = false
    private var pending: [String: LanConnection] = [:]
    private var probePayload: [String: Any] = [:]
    /// 候选监听端口。顺序：41234 → 0（系统随机分配）→ 41235…41244。
    /// 系统分配端口几乎不会被占用，因此「11 个端口都被占用」不可能再导致建房失败。
    private var candidates: [UInt16] = []
    private var candidateIndex = 0
    private var currentCandidate: UInt16 = 0
    /// 同一个端口最多重试几次。房主「取消房间 → 重新建房」时，上一个监听器的
    /// socket 释放是异步的，立刻重新 bind 会 EADDRINUSE；不重试就会一路顺延端口。
    private var samePortRetries = 0
    private var retryWork: DispatchWorkItem?
    private var waitWork: DispatchWorkItem?
    private var stopped = false
    /// 每个候选端口失败时的真实错误码，用于给出可执行的提示（权限 / 占用 / 其它）。
    private var lastErrors: [String] = []
    /// 房间规则：是否允许落点/可吃子提示，写进 TXT 供客机读取
    let hintsEnabled: Bool

    var serviceName: String { "QY-\(roomCode)-\(size)" }

    init(roomCode: String, gameId: String, size: Int, hintsEnabled: Bool = true) {
        self.roomCode = roomCode
        self.gameId = gameId == LanProto.xiangqiGame ? LanProto.xiangqiGame : LanProto.goGame
        self.size = size
        self.hintsEnabled = hintsEnabled
    }

    /// probe_ack 的 p 负载，由 Hub 在状态变化时更新
    func setProbePayload(_ payload: [String: Any]) {
        queue.async { self.probePayload = payload }
    }

    func start(preferredPort: UInt16 = LanProto.defaultPort, tries: Int = LanProto.portTries) {
        queue.async {
            self.addr = LanProto.localIPv4Address()
            var list: [UInt16] = [preferredPort, 0]
            for port in LanProto.portCandidates where !list.contains(port) {
                list.append(port)
            }
            _ = tries
            self.candidates = list
            self.candidateIndex = 0
            self.samePortRetries = LanProto.samePortRetries
            self.lastErrors.removeAll()
            self.stopped = false
            self.tryListen()
        }
    }

    private func tryListen() {
        guard !stopped else { return }
        guard candidateIndex < candidates.count else {
            failAll()
            return
        }
        let candidate = candidates[candidateIndex]
        currentCandidate = candidate
        let nwPort: NWEndpoint.Port
        if candidate == 0 {
            nwPort = .any
        } else if let value = NWEndpoint.Port(rawValue: candidate) {
            nwPort = value
        } else {
            advanceCandidate()
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try NWListener(using: params, on: nwPort)
        } catch {
            record(error as? NWError)
            advanceCandidate()
            return
        }
        l.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        // 只捕获 weak：监听器由 `listener` 持有；强捕获会形成 retain cycle，
        // 让已经失败的监听器一直活到进程结束，端口也无法回收。
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, !self.stopped, self.listener === l else { return }
            switch state {
            case .ready:
                self.waitWork?.cancel()
                self.waitWork = nil
                self.port = l.port?.rawValue ?? candidate
                self.publishServices()
                self.onReady?(self.port, self.addr)
            case .failed(let error):
                l.cancel()
                self.listener = nil
                self.record(error)
                self.handleFailure(error, candidate: candidate)
            case .waiting(let error):
                // 本地网络未授权、端口被别的进程占用时都可能停在 waiting。
                // 记下真实错误，1.5s 仍未 ready 就换下一个候选（含系统分配端口）。
                self.record(error)
                self.waitWork?.cancel()
                let item = DispatchWorkItem { [weak self, weak l] in
                    guard let self, let l, !self.stopped, self.listener === l else { return }
                    l.cancel()
                    self.listener = nil
                    self.advanceCandidate()
                }
                self.waitWork = item
                self.queue.asyncAfter(deadline: .now() + 1.5, execute: item)
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    /// 失败处理：权限被拒直接整体失败（继续试其它端口没有意义）；
    /// 固定端口先原地重试 3 次（等旧 socket 释放），再换下一个候选。
    private func handleFailure(_ error: NWError, candidate: UInt16) {
        if isPermissionDenied(error) {
            failAll()
            return
        }
        if candidate != 0, samePortRetries > 0 {
            samePortRetries -= 1
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.tryListen()
            }
            retryWork?.cancel()
            retryWork = item
            queue.asyncAfter(deadline: .now() + 0.25, execute: item)
            return
        }
        advanceCandidate()
    }

    private func advanceCandidate() {
        guard !stopped else { return }
        waitWork?.cancel()
        waitWork = nil
        candidateIndex += 1
        samePortRetries = LanProto.samePortRetries
        tryListen()
    }

    private func failAll() {
        guard !stopped else { return }
        stopped = true
        let detail = lastErrors.last ?? "未知错误"
        let denied = lastErrors.contains { $0.contains("EACCES") || $0.contains("EPERM") || $0.contains("65555") }
        if denied {
            onError?("无法创建房间：本地网络权限被拒绝。请到 系统设置 → 清弈 → 本地网络 打开开关后重试。（\(detail)）")
        } else {
            onError?("无法创建房间：\(candidates.count) 个候选端口（含系统分配端口）全部监听失败。最后一次错误：\(detail)")
        }
    }

    private func isPermissionDenied(_ error: NWError) -> Bool {
        switch error {
        case .posix(let code) where code == .EACCES || code == .EPERM:
            return true
        case .dns(let code) where code == -65555:
            // kDNSServiceErr_PolicyDenied：本地网络权限被拒
            return true
        default:
            return false
        }
    }

    private func record(_ error: NWError?) {
        let text: String
        if let error {
            switch error {
            case .posix(let code):
                let reason = String(cString: strerror(code.rawValue))
                text = "POSIX \(code.rawValue) \(reason)"
            case .dns(let code):
                text = "DNS \(code)"
            case .tls(let status):
                text = "TLS \(status)"
            @unknown default:
                text = "\(error)"
            }
        } else {
            text = "NWListener 创建失败（无 NWError）"
        }
        let line = "\(currentCandidate == 0 ? "系统分配端口" : "端口 \(currentCandidate)")：\(text)"
        if !lastErrors.contains(line) { lastErrors.append(line) }
    }

    // MARK: - Bonjour

    private func txtDict(port: UInt16) -> [String: String] {
        var dict: [String: String] = [
            "room": roomCode,
            "size": String(size),
            "game": gameId,
            "port": String(port),
            "hints": hintsEnabled ? "1" : "0",
            "pid": String(pid),
            "iid": iid,
            "ts": String(LanProto.nowMs())
        ]
        if !addr.isEmpty { dict["addr"] = addr }
        return dict
    }

    /// Bonjour 公告。端口由系统分配时只有 ready 之后才知道真实端口，
    /// 所以统一在这里用 NetService 同时公告统一类型与棋种专用类型。
    private func publishServices() {
        let value = port
        guard value > 0 else { return }
        let types = [LanProto.serviceTypeMDNS,
                     gameId == LanProto.xiangqiGame ? "_qingyi-xiangqi._tcp." : "_qingyi-go._tcp."]
        let name = serviceName
        let txt = LanProto.txtData(txtDict(port: value))
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            for service in self.netServices { service.stop() }
            self.netServices.removeAll()
            for type in types {
                let service = NetService(domain: "local.", type: type, name: name, port: Int32(value))
                service.setTXTRecord(txt)
                service.publish()
                self.netServices.append(service)
            }
        }
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        let client = LanConnection(connection, queue: queue)
        pending[client.id] = client

        let item = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client, self.pending[client.id] != nil else { return }
            self.pending.removeValue(forKey: client.id)
            client.close("等待首帧超时")
        }
        queue.asyncAfter(deadline: .now() + Double(LanProto.hostFirstFrameMs) / 1000, execute: item)

        client.firstFrameGate = { [weak self, weak client] msg in
            guard let self, let client else { return false }
            self.pending.removeValue(forKey: client.id)
            if LanProto.type(msg) == LanMsg.probe {
                let ack = LanProto.message(LanMsg.probeAck, room: self.roomCode,
                                           from: "host", payload: self.probePayload)
                client.send(ack, closeAfter: true)
                return false
            }
            return self.attach(client)
        }
        client.start()
    }

    /// 返回 true 表示继续把首帧交给 onMessage。
    private func attach(_ client: LanConnection) -> Bool {
        if let existing = guest, existing !== client {
            if guestHandshaked {
                let reject = LanProto.message(LanMsg.helloReject, room: roomCode, from: "host",
                                              payload: ["ok": false,
                                                        "code": LanMsg.eRoomFull,
                                                        "reason": LanMsg.eRoomFull,
                                                        "message": "房间已有对手"])
                client.send(reject, closeAfter: true)
                return false
            }
            existing.firstFrameGate = nil
            existing.close("被新连接替换")
        }
        guest = client
        guestHandshaked = false
        client.onMessage = { [weak self] msg in self?.onMessage?(msg) }
        client.onClosed = { [weak self] reason in self?.detach(client, reason: reason) }
        onGuestChanged?(true)
        return true
    }

    private func detach(_ client: LanConnection, reason: String) {
        guard guest === client else { return }
        guest = nil
        guestHandshaked = false
        onGuestChanged?(false)
    }

    func markHandshaked() {
        queue.async { self.guestHandshaked = true }
    }

    /// `guest` 只在内部串行队列上读写；外部调用一律入队，避免跨线程访问引用。
    @discardableResult
    func send(_ msg: [String: Any]) -> Bool {
        queue.async { [weak self] in
            guard let self, let guest = self.guest else { return }
            guest.send(msg)
        }
        return true
    }

    func closeGuest(_ reason: String = "房主已结束连接") {
        queue.async { [weak self] in
            guard let self, let client = self.guest else { return }
            self.guest = nil
            self.guestHandshaked = false
            client.close(reason)
            self.onGuestChanged?(false)
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                if let completion { DispatchQueue.main.async { completion() } }
                return
            }
            self.stopped = true
            self.retryWork?.cancel()
            self.retryWork = nil
            self.waitWork?.cancel()
            self.waitWork = nil
            self.pending.removeAll()
            self.guest?.close("房主已关闭房间")
            self.guest = nil
            self.guestHandshaked = false
            self.listener?.cancel()
            self.listener = nil
            let services = self.netServices
            self.netServices.removeAll()
            DispatchQueue.main.async {
                for service in services { service.stop() }
                completion?()
            }
        }
    }
}
