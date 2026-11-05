import Foundation

/// KataGo 围棋引擎的 Swift 封装 (进程内 GTP)
final class KataGoEngine {

    static let shared = KataGoEngine()

    /// 该档位及以上使用 KataGo, 以下保留本地快速 AI
    static let minimumLevel = 7

    private var handle: OpaquePointer?
    private var isReady = false
    private var isFailed = false
    private let lock = NSLock()

    private static let columns = Array("ABCDEFGHJKLMNOPQRST")

    enum Result {
        case move(GoPoint)
        case pass
        case unavailable
    }

    private init() {}

    func preload() {
        lock.lock()
        defer { lock.unlock() }
        _ = ensureReadyLocked()
    }

    /// 返回引擎着法; nil 表示 PASS / 不可用 / 超时
    func bestMove(size: Int, komi: Double, history: [GoMove],
                  board: [[GoColor]], color: GoColor, level: Int) -> Result {
        lock.lock()
        defer { lock.unlock() }

        guard ensureReadyLocked() else { return .unavailable }

        guard sendOk("boardsize \(size)"),
              sendOk("komi \(komi)"),
              sendOk("clear_board") else { return .unavailable }

        let visits = Self.visitCount(level: level)
        _ = sendOk("kata-set-param maxVisits \(visits)")

        if history.isEmpty {
            // 让子/摆子局面: 按棋盘现有棋子补齐
            for y in 0..<size {
                for x in 0..<size {
                    let stone = board[y][x]
                    if stone == .empty { continue }
                    guard sendOk("play \(name(of: stone)) \(coordinate(GoPoint(x: x, y: y), size: size))") else {
                        return .unavailable
                    }
                }
            }
        } else {
            for move in history {
                let side = name(of: move.color)
                let command: String
                if let point = move.point {
                    command = "play \(side) \(coordinate(point, size: size))"
                } else {
                    command = "play \(side) pass"
                }
                guard sendOk(command) else { return .unavailable }
            }
        }

        let timeout = max(15000, visits * 120 + 10000)
        send("genmove \(name(of: color))")
        guard let response = readResponse(timeoutMs: timeout) else {
            send("stop")
            _ = readResponse(timeoutMs: 3000)
            return .unavailable
        }

        let text = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "pass" || text == "resign" || text.isEmpty { return .pass }
        if let point = Self.parseCoordinate(response, size: size) {
            return .move(point)
        }
        return .unavailable
    }

    // MARK: - 生命周期

    private func ensureReadyLocked() -> Bool {
        if isReady { return true }
        if isFailed { return false }

        guard let model = Bundle.main.path(forResource: "kata", ofType: "bin.gz"),
              let config = Bundle.main.path(forResource: "gtp", ofType: "cfg") else {
            isFailed = true
            return false
        }

        let created: OpaquePointer? = model.withCString { modelPtr in
            config.withCString { configPtr in
                qy_katago_create(modelPtr, configPtr)
            }
        }
        guard let engine = created else {
            isFailed = true
            return false
        }
        handle = engine

        // 初始化(加载网络)期间命令会排队, 用 name 探测就绪
        send("name")
        guard readResponse(timeoutMs: 90000) != nil else {
            markFailed()
            return false
        }

        _ = sendOk("kata-set-rules chinese")
        isReady = true
        return true
    }

    private func markFailed() {
        isFailed = true
        if let engine = handle {
            qy_katago_destroy(engine)
            handle = nil
        }
    }

    // MARK: - GTP 通信

    @discardableResult
    private func sendOk(_ command: String) -> Bool {
        send(command)
        return readResponse(timeoutMs: 10000) != nil
    }

    private func send(_ command: String) {
        guard let engine = handle else { return }
        command.withCString { qy_katago_send(engine, $0) }
    }

    private func readResponse(timeoutMs: Int) -> String? {
        guard let engine = handle else { return nil }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1000))
            var buffer = [CChar](repeating: 0, count: 8192)
            let result = qy_katago_read_line(engine, &buffer, Int32(buffer.count), Int32(remaining))
            if result < 0 { return nil }
            if result == 0 { continue }

            let trimmed = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("?") { return nil }
            if trimmed.hasPrefix("=") {
                let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                // 去掉可选的命令 id
                let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if let first = parts.first, Int(first) != nil {
                    return parts.count > 1 ? String(parts[1]) : ""
                }
                return String(body)
            }
        }
        return nil
    }

    // MARK: - 参数与坐标

    private static func visitCount(level: Int) -> Int {
        switch level {
        case 8: return 150
        case 9: return 400
        case 10...: return 900
        default: return 50
        }
    }

    private func name(of color: GoColor) -> String {
        color == .black ? "black" : "white"
    }

    private func coordinate(_ point: GoPoint, size: Int) -> String {
        guard point.x >= 0, point.x < Self.columns.count else { return "pass" }
        return "\(Self.columns[point.x])\(size - point.y)"
    }

    private static func parseCoordinate(_ text: String, size: Int) -> GoPoint? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").last.map(String.init) ?? text
        let chars = Array(token.uppercased())
        guard chars.count >= 2,
              let columnIndex = columns.firstIndex(of: chars[0]),
              let rank = Int(String(chars[1...])) else { return nil }
        let y = size - rank
        guard y >= 0, y < size else { return nil }
        return GoPoint(x: columnIndex, y: y)
    }
}
