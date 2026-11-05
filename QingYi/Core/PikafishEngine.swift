import Foundation

/// Pikafish 中国象棋引擎的 Swift 封装.
/// 引擎以静态库形式链接进 App, 在本进程内跑 UCI 主循环 (iOS 无法创建子进程).
final class PikafishEngine {

    static let shared = PikafishEngine()

    /// 该档位及以上使用 Pikafish, 以下保留本地快速 AI
    static let minimumLevel = 7

    private var handle: OpaquePointer?
    private var isReady = false
    private var isFailed = false
    private let lock = NSLock()

    private init() {}

    /// 后台预热, 避免第一次落子时才加载 48MB 网络
    func preload() {
        lock.lock()
        defer { lock.unlock() }
        _ = ensureReadyLocked()
    }

    /// 返回引擎给出的着法 (起点, 终点); nil 表示不可用或超时
    func bestMove(fen: String, level: Int) -> (from: GoPoint, to: GoPoint)? {
        lock.lock()
        defer { lock.unlock() }

        guard ensureReadyLocked() else { return nil }
        guard let uci = searchLocked(fen: fen, level: level) else { return nil }
        return Self.parse(uciMove: uci)
    }

    // MARK: - 引擎生命周期

    private func ensureReadyLocked() -> Bool {
        if isReady { return true }
        if isFailed { return false }

        guard let path = Bundle.main.path(forResource: "pikafish", ofType: "nnue") else {
            isFailed = true
            return false
        }

        let created: OpaquePointer? = path.withCString { qy_engine_create($0) }
        guard let engine = created else {
            isFailed = true
            return false
        }
        handle = engine

        send("uci")
        guard waitFor(prefix: "uciok", timeoutMs: 20000) else {
            markFailed()
            return false
        }

        send("setoption name Threads value 2")
        send("setoption name Hash value 32")
        send("isready")
        guard waitFor(prefix: "readyok", timeoutMs: 20000) else {
            markFailed()
            return false
        }

        isReady = true
        return true
    }

    private func markFailed() {
        isFailed = true
        if let engine = handle {
            qy_engine_destroy(engine)
            handle = nil
        }
    }

    // MARK: - UCI

    private func searchLocked(fen: String, level: Int) -> String? {
        guard handle != nil else { return nil }

        let thinkMs = Self.thinkingTimeMs(level: level)
        send("position fen \(fen)")
        send("go movetime \(thinkMs)")

        let timeout = thinkMs + 8000
        if let line = waitForLine(prefix: "bestmove", timeoutMs: timeout) {
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            let move = String(parts[1])
            return move == "(none)" ? nil : move
        }

        send("stop")
        return nil
    }

    private func send(_ command: String) {
        guard let engine = handle else { return }
        command.withCString { qy_engine_send(engine, $0) }
    }

    private func waitFor(prefix: String, timeoutMs: Int) -> Bool {
        waitForLine(prefix: prefix, timeoutMs: timeoutMs) != nil
    }

    private func waitForLine(prefix: String, timeoutMs: Int) -> String? {
        guard let engine = handle else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        while Date() < deadline {
            let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1000))
            let result = qy_engine_read_line(engine, &buffer, Int32(buffer.count), Int32(remaining))
            if result < 0 { return nil }
            if result == 0 { continue }
            let line = String(cString: buffer)
            if line.hasPrefix(prefix) { return line }
        }
        return nil
    }

    // MARK: - 参数

    private static func thinkingTimeMs(level: Int) -> Int {
        switch level {
        case 8: return 400
        case 9: return 800
        case 10...: return 1500
        default: return 200
        }
    }

    private static func parse(uciMove: String) -> (from: GoPoint, to: GoPoint)? {
        let chars = Array(uciMove)
        guard chars.count >= 4 else { return nil }

        let letters = Array("abcdefghi")
        guard let fx = letters.firstIndex(of: chars[0]),
              let tx = letters.firstIndex(of: chars[2]),
              let fromRank = chars[1].wholeNumberValue,
              let toRank = chars[3].wholeNumberValue else { return nil }

        let fy = 9 - fromRank
        let ty = 9 - toRank
        guard (0..<XiangqiGame.rows).contains(fy), (0..<XiangqiGame.rows).contains(ty) else {
            return nil
        }
        return (GoPoint(x: fx, y: fy), GoPoint(x: tx, y: ty))
    }
}
