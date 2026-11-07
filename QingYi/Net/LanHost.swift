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
    private var remainingTries = 0
    private var nextPort: UInt16 = LanProto.defaultPort
    private var stopped = false

    var serviceName: String { "QY-\(roomCode)-\(size)" }
    var isGuestHandshaked: Bool { guestHandshaked }
    var hasGuest: Bool { guest != nil }
    var guestIdleSeconds: TimeInterval { guest?.idleSeconds ?? 0 }

    init(roomCode: String, gameId: String, size: Int) {
        self.roomCode = roomCode
        self.gameId = gameId == LanProto.xiangqiGame ? LanProto.xiangqiGame : LanProto.goGame
        self.size = size
    }

    /// probe_ack 的 p 负载，由 Hub 在状态变化时更新
    func setProbePayload(_ payload: [String: Any]) {
        queue.async { self.probePayload = payload }
    }

    func start(preferredPort: UInt16 = LanProto.defaultPort, tries: Int = LanProto.portTries) {
        queue.async {
            self.addr = LanProto.localIPv4Address()
            self.remainingTries = max(1, tries)
            self.nextPort = preferredPort
            self.stopped = false
            self.tryListen()
        }
    }

    private func tryListen() {
        guard !stopped else { return }
        guard remainingTries > 0 else {
            onError?("端口 \(LanProto.defaultPort) 起连续 \(LanProto.portTries) 个端口都被占用")
            return
        }
        remainingTries -= 1
        let candidate = nextPort
        nextPort = candidate >= UInt16.max ? LanProto.defaultPort : candidate + 1
        guard let nwPort = NWEndpoint.Port(rawValue: candidate) else {
            tryListen()
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: nwPort) else {
            tryListen()
            return
        }
        l.service = NWListener.Service(name: serviceName,
                                       type: LanProto.serviceTypeNW,
                                       domain: nil,
                                       txtRecord: LanProto.txtData(txtDict(port: candidate)))
        l.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue ?? candidate
                self.publishExtra()
                self.onReady?(self.port, self.addr)
            case .failed:
                l.cancel()
                self.listener = nil
                self.tryListen()
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    // MARK: - Bonjour

    private func txtDict(port: UInt16) -> [String: String] {
        var dict: [String: String] = [
            "room": roomCode,
            "size": String(size),
            "game": gameId,
            "port": String(port),
            "pid": String(pid),
            "iid": iid,
            "ts": String(LanProto.nowMs())
        ]
        if !addr.isEmpty { dict["addr"] = addr }
        return dict
    }

    /// 棋种专用类型仅作广告（同一端口），便于其它 iOS 端或未来版本发现。
    private func publishExtra() {
        let type = gameId == LanProto.xiangqiGame ? "_qingyi-xiangqi._tcp." : "_qingyi-go._tcp."
        let name = serviceName
        let value = port
        let txt = LanProto.txtData(txtDict(port: port))
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            for service in self.netServices { service.stop() }
            self.netServices.removeAll()
            let service = NetService(domain: "local.", type: type, name: name, port: Int32(value))
            service.setTXTRecord(txt)
            service.publish()
            self.netServices.append(service)
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

    @discardableResult
    func send(_ msg: [String: Any]) -> Bool {
        guard let guest else { return false }
        return guest.send(msg)
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

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
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
            }
        }
    }
}
