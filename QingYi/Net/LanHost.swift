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
    /// 同一个端口最多重试几次。房主「取消房间 → 重新建房」时，上一个监听器的
    /// socket 释放是异步的，立刻重新 bind 会 EADDRINUSE；不重试就会一路顺延端口，
    /// 最终和 Android 的 41234 对不上（曾出现 iOS 落在 41244）。
    private var samePortRetries = 0
    private var retryWork: DispatchWorkItem?

    var serviceName: String { "QY-\(roomCode)-\(size)" }

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
            self.samePortRetries = LanProto.samePortRetries
            self.tryListen()
        }
    }

    private func tryListen() {
        guard !stopped else { return }
        guard remainingTries > 0 else {
            stopped = true
            onError?("端口 \(LanProto.defaultPort) 起连续 \(LanProto.portTries) 个端口都被占用，无法建房")
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
            scheduleRetrySamePort()
            return
        }
        l.service = NWListener.Service(name: serviceName,
                                       type: LanProto.serviceTypeNW,
                                       domain: nil,
                                       txtRecord: LanProto.txtData(txtDict(port: candidate)))
        l.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        // 只捕获 weak：监听器由 `listener` 持有；强捕获会形成 retain cycle，
        // 让已经失败的监听器一直活到进程结束，端口也无法回收。
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, !self.stopped, self.listener === l else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue ?? candidate
                self.publishExtra()
                self.onReady?(self.port, self.addr)
            case .failed:
                l.cancel()
                self.listener = nil
                self.scheduleRetrySamePort()
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    /// 同一个端口先重试几次（间隔 250ms），仍然失败才顺延到下一个端口。
    /// 这样「取消再建房」不会把端口一路推到 41244。
    private func scheduleRetrySamePort() {
        guard !stopped else { return }
        if samePortRetries > 0 {
            samePortRetries -= 1
            let target = nextPort > LanProto.defaultPort ? nextPort - 1 : LanProto.defaultPort
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.nextPort = target
                // 这次重试不消耗 remainingTries，等真正顺延时才算一次
                self.remainingTries += 1
                self.tryListen()
            }
            retryWork?.cancel()
            retryWork = item
            queue.asyncAfter(deadline: .now() + 0.25, execute: item)
            return
        }
        samePortRetries = LanProto.samePortRetries
        tryListen()
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
