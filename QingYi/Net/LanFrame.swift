import Foundation
import Network

enum LanFrameError: Error {
    case tooLarge(Int)
    case badLength(Int)
    case badJSON
}

/// TCP 帧编解码：4 字节大端长度 + UTF-8 JSON。对端实现：Android `FrameIO`。
enum LanFrame {
    static func encode(_ msg: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: msg, options: [])
        guard body.count <= LanProto.maxFrame else { throw LanFrameError.tooLarge(body.count) }
        var out = Data(capacity: body.count + 4)
        let length = UInt32(body.count)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(body)
        return out
    }

    /// 从缓冲区取出一帧；返回 nil 表示数据还不够。
    static func decode(_ buffer: inout Data) throws -> [String: Any]? {
        guard buffer.count >= 4 else { return nil }
        let header = [UInt8](buffer.prefix(4))
        let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        guard length > 0, length <= LanProto.maxFrame else { throw LanFrameError.badLength(length) }
        guard buffer.count >= 4 + length else { return nil }
        let start = buffer.startIndex + 4
        let end = start + length
        let body = buffer[start..<end]
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)),
              let msg = object as? [String: Any] else {
            throw LanFrameError.badJSON
        }
        buffer.removeSubrange(buffer.startIndex..<end)
        return msg
    }
}

/// 一条 TCP 连接：串行收帧、按帧发送。
/// 首帧可选交给 `firstFrameGate` 判定（房主用它区分 probe 与 hello），
/// 返回 true 表示继续按常规消息交给 `onMessage`。
final class LanConnection {
    let id = UUID().uuidString

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false
    private var notifyClosed = false
    private var firstFrameDone = false
    private var lastReceiveAt = Date()

    var firstFrameGate: (([String: Any]) -> Bool)?
    var onMessage: (([String: Any]) -> Void)?
    var onClosed: ((String) -> Void)?
    var onReady: (() -> Void)?

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .failed(let error):
                self.close(error.localizedDescription)
            case .cancelled:
                self.close("连接已关闭")
            default:
                break
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.connection.start(queue: self.queue)
            self.receive()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: LanProto.maxFrame) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastReceiveAt = Date()
                self.buffer.append(data)
                self.drain()
            }
            if let error {
                self.close(error.localizedDescription)
                return
            }
            if isComplete {
                self.close("对端已关闭连接")
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while !closed {
            let msg: [String: Any]?
            do {
                msg = try LanFrame.decode(&buffer)
            } catch {
                close("帧解析失败")
                return
            }
            guard let msg else { return }
            if !firstFrameDone {
                firstFrameDone = true
                if let gate = firstFrameGate, !gate(msg) { return }
            }
            onMessage?(msg)
        }
    }

    @discardableResult
    func send(_ msg: [String: Any], closeAfter: Bool = false) -> Bool {
        guard !closed else { return false }
        let frame: Data
        do {
            frame = try LanFrame.encode(msg)
        } catch {
            return false
        }
        // 这里必须强引用 self：探活连接在 pending 表移除后只剩这次发送撑着，
        // 弱引用会让 data 还没交给系统就被释放。
        queue.async {
            guard !self.closed else { return }
            self.connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    self.close(error.localizedDescription)
                    return
                }
                if closeAfter { self.close("探活完成") }
            })
        }
        return true
    }

    func close(_ reason: String = "连接已关闭") {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.connection.cancel()
            if !self.notifyClosed {
                self.notifyClosed = true
                self.onClosed?(reason)
            }
            // 断开后释放回调，避免与持有者形成引用环
            self.onMessage = nil
            self.onClosed = nil
            self.onReady = nil
            self.firstFrameGate = nil
        }
    }
}
