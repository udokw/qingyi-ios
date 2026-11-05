import Foundation

/// Pachi 围棋引擎的 Swift 封装 (进程内 GTP)
final class PachiEngine {

    static let shared = PachiEngine()

    /// 该档位及以下使用 Pachi, 更高档位改用 KataGo
    static let maximumLevel = 6

    private var handle: OpaquePointer?
    private var readyLevel = 0
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

    func preload(level: Int) {
        lock.lock()
        defer { lock.unlock() }
        _ = ensureReadyLocked(level: level)
    }

    func bestMove(size: Int, komi: Double, history: [GoMove],
                  board: [[GoColor]], color: GoColor, level: Int) -> Result {
        lock.lock()
        defer { lock.unlock() }

        guard ensureReadyLocked(level: level) else { return .unavailable }

        guard sendOk("boardsize \(size)"),
              sendOk("komi \(komi)"),
              sendOk("clear_board") else { return .unavailable }

        if history.isEmpty {
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

        let timeout = max(15000, Int(Self.timePerMove(level: level) * 1000) + 20000)
        send("genmove \(name(of: color))")
        guard let response = readResponse(timeoutMs: timeout) else { return .unavailable }

        let text = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "pass" || text == "resign" || text.isEmpty { return .pass }
        if let point = Self.parseCoordinate(response, size: size) {
            return .move(point)
        }
        return .unavailable
    }

    // MARK: - 生命周期

    private func ensureReadyLocked(level: Int) -> Bool {
        if isReady && readyLevel == level { return true }
        if isFailed { return false }

        // 档位变化时重建引擎, 因为每手思考时间由启动参数 -t 决定
        if let engine = handle {
            qy_pachi_destroy(engine)
            handle = nil
        }
        isReady = false

        guard let resourcePath = Bundle.main.resourcePath else {
            isFailed = true
            return false
        }

        let created: OpaquePointer? = resourcePath.withCString { dir in
            qy_pachi_create(dir, Self.timePerMove(level: level))
        }
        guard let engine = created else {
            isFailed = true
            return false
        }
        handle = engine

        // 加载 pattern 数据期间命令会排队, 用 name 探测就绪
        send("name")
        guard readResponse(timeoutMs: 30000) != nil else {
            markFailed()
            return false
        }

        readyLevel = level
        isReady = true
        return true
    }

    private func markFailed() {
        isFailed = true
        if let engine = handle {
            qy_pachi_destroy(engine)
            handle = nil
        }
        isReady = false
    }

    // MARK: - GTP 通信

    @discardableResult
    private func sendOk(_ command: String) -> Bool {
        send(command)
        return readResponse(timeoutMs: 10000) != nil
    }

    private func send(_ command: String) {
        guard let engine = handle else { return }
        command.withCString { qy_pachi_send(engine, $0) }
    }

    private func readResponse(timeoutMs: Int) -> String? {
        guard let engine = handle else { return nil }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1000))
            var buffer = [CChar](repeating: 0, count: 8192)
            let result = qy_pachi_read_line(engine, &buffer, Int32(buffer.count), Int32(remaining))
            if result < 0 { return nil }
            if result == 0 { continue }

            let trimmed = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("?") { return nil }
            if trimmed.hasPrefix("=") {
                let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
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

    /// 每手思考时间 (秒), 档位越低越快
    static func timePerMove(level: Int) -> Double {
        switch level {
        case 1: return 0.30
        case 2: return 0.50
        case 3: return 0.80
        case 4: return 1.20
        case 5: return 1.80
        default: return 2.50
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
