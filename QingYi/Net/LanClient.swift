import Foundation
import Network

/// 局域网客机：单次连接 + 收发。重连由 Hub 负责。
final class LanClient {
    var onMessage: (([String: Any]) -> Void)?
    var onClosed: ((String) -> Void)?
    var onReady: (() -> Void)?

    private let queue = DispatchQueue(label: "qingyi.lan.client")
    private var connection: LanConnection?
    private var connectTimeout: DispatchWorkItem?
    private(set) var connected = false

    var idleSeconds: TimeInterval { connection?.idleSeconds ?? 0 }

    func connect(host: String, port: UInt16, timeout: TimeInterval = 6) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            DispatchQueue.main.async { [weak self] in self?.onClosed?("地址或端口无效") }
            return
        }
        let nw = NWConnection(host: NWEndpoint.Host(trimmed), port: nwPort, using: .tcp)
        let client = LanConnection(nw, queue: queue)
        connection = client

        client.onReady = { [weak self] in
            guard let self else { return }
            self.connected = true
            self.connectTimeout?.cancel()
            self.onReady?()
        }
        client.onMessage = { [weak self] msg in self?.onMessage?(msg) }
        client.onClosed = { [weak self] reason in
            guard let self else { return }
            self.connected = false
            self.onClosed?(reason)
        }
        client.start()

        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.connected else { return }
            self.connection?.close("连接超时")
        }
        connectTimeout = item
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    @discardableResult
    func send(_ msg: [String: Any]) -> Bool {
        guard let connection else { return false }
        return connection.send(msg)
    }

    func close(_ reason: String = "已断开连接") {
        connectTimeout?.cancel()
        connection?.close(reason)
    }
}
