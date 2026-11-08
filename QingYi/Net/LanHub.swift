import Foundation
import Combine

/// 主时钟 + 读秒。只在房主侧作为权威运行；客机只接收快照做显示插值。
/// 下标：0 = 黑/红先手，1 = 白/黑后手。与 Android `LanClock` 一致。
final class LanClock {
    let mainSec: Int
    let byoYomiSec: Int
    let periods: Int

    private var mainMs = [Int64](repeating: 0, count: 2)
    private var periodsLeft = [Int](repeating: 0, count: 2)
    private var periodRemain = [Int64](repeating: 0, count: 2)

    private var turn = 0
    private var turnStart: Int64 = 0
    private var running = false
    private var paused = false
    private var timeoutColor = -1

    init(mainSec: Int, byoYomiSec: Int, periods: Int) {
        self.mainSec = max(0, mainSec)
        self.byoYomiSec = max(0, byoYomiSec)
        self.periods = max(0, periods)
        for i in 0..<2 {
            mainMs[i] = Int64(self.mainSec) * 1000
            periodsLeft[i] = self.periods
            periodRemain[i] = Int64(self.byoYomiSec) * 1000
        }
    }

    var active: Bool { mainSec > 0 }
    var currentTurn: Int { turn }
    var isRunning: Bool { running }
    var isPaused: Bool { paused }
    var timedOutColor: Int { timeoutColor }

    func start(firstColor: Int) {
        turn = firstColor
        turnStart = LanProto.uptimeMs()
        running = active
    }

    func stop() { running = false }

    /// 断线：只结算到最后一次收到对方消息的时刻，再冻结计时。
    func pauseAt(_ lastContactAt: Int64) {
        guard running else { return }
        charge(max(turnStart, lastContactAt))
        running = false
        paused = true
    }

    func resume() {
        guard active, timeoutColor < 0 else { return }
        turnStart = LanProto.uptimeMs()
        running = true
        paused = false
    }

    func onMove(_ color: Int) {
        let now = LanProto.uptimeMs()
        charge(now)
        guard running else { return }
        turn = 1 - turn
        turnStart = now
    }

    func setTurn(_ color: Int) {
        guard color >= 0, color <= 1 else { return }
        turn = color
        turnStart = LanProto.uptimeMs()
    }

    func tick() {
        guard running else { return }
        charge(LanProto.uptimeMs())
    }

    private func charge(_ now: Int64) {
        guard running, turn >= 0, turn <= 1 else { return }
        var elapsed = now - turnStart
        guard elapsed > 0 else { return }
        turnStart = now

        if mainMs[turn] > 0 {
            if elapsed < mainMs[turn] {
                mainMs[turn] -= elapsed
                return
            }
            elapsed -= mainMs[turn]
            mainMs[turn] = 0
            periodsLeft[turn] = periods
            periodRemain[turn] = Int64(byoYomiSec) * 1000
        }

        if periodRemain[turn] <= 0 {
            running = false
            timeoutColor = turn
            return
        }
        while elapsed > 0 {
            if elapsed < periodRemain[turn] {
                periodRemain[turn] -= elapsed
                return
            }
            elapsed -= periodRemain[turn]
            periodsLeft[turn] -= 1
            periodRemain[turn] = Int64(byoYomiSec) * 1000
            if periodsLeft[turn] <= 0 {
                running = false
                timeoutColor = turn
                return
            }
        }
    }

    func snapshot(moveNo: Int) -> [String: Any] {
        [
            "turn": turn == 0 ? "B" : "W",
            "blackRemainMs": remain(0),
            "whiteRemainMs": remain(1),
            "blackPeriods": periodsLeft[0],
            "whitePeriods": periodsLeft[1],
            "blackByoYomi": inByoYomi(0),
            "whiteByoYomi": inByoYomi(1),
            "running": running,
            "paused": paused,
            "moveNo": moveNo,
            "serverTime": LanProto.nowMs()
        ]
    }

    func remain(_ color: Int) -> Int64 {
        mainMs[color] > 0 ? mainMs[color] : max(0, periodRemain[color])
    }

    func periodsRemaining(_ color: Int) -> Int { periodsLeft[color] }
    func inByoYomi(_ color: Int) -> Bool { mainMs[color] <= 0 }
}

/// 落子裁决结果，字段与 Android `GameAdapter.ApplyResult` 对应。
struct LanApplyResult {
    var ok = false
    var code = ""
    var message = ""
    var pass = false
    var x = -1, y = -1
    var fx = -1, fy = -1, tx = -1, ty = -1
    var captured = 0
    var nextTurn = 1
    var moveNo = 0
    var hash = ""
}

/// 一局联机棋的状态容器（与棋种无关）。
/// 房主侧调用 `applyAuthority` 做权威裁决；客机侧只用 `applyAck` / `restore`。
final class LanGameSession {
    let room: String
    let game: String
    var matchId: String

    var moveNo = 0
    var consecutivePasses = 0
    var size: Int
    var komi: Double = 7.5

    private(set) var go: GoGame?
    private(set) var xiangqi: XiangqiGame?

    init(room: String, game: String, matchId: String? = nil) {
        self.room = room
        self.game = game == LanProto.xiangqiGame ? LanProto.xiangqiGame : LanProto.goGame
        if let matchId, !matchId.isEmpty {
            self.matchId = matchId
        } else {
            self.matchId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        }
        if self.game == LanProto.goGame {
            size = LanProto.goSize
            komi = LanProto.goKomi
            let g = GoGame(size: LanProto.goSize)
            g.komi = komi
            go = g
        } else {
            size = XiangqiGame.cols
            komi = 0
            xiangqi = XiangqiGame()
        }
    }

    func reset(komi newKomi: Double) {
        komi = game == LanProto.goGame ? newKomi : 0
        if game == LanProto.goGame {
            let g = GoGame(size: LanProto.goSize)
            g.komi = komi
            go = g
            size = g.size
        } else {
            xiangqi = XiangqiGame()
            size = XiangqiGame.cols
        }
        moveNo = 0
        consecutivePasses = 0
    }

    func turn() -> Int {
        if game == LanProto.goGame {
            return go?.turn == .white ? 2 : 1
        }
        return xiangqi?.turn == .black ? 2 : 1
    }

    func moveCount() -> Int {
        game == LanProto.goGame ? (go?.history.count ?? 0) : (xiangqi?.history.count ?? 0)
    }

    func supportsPass() -> Bool { game == LanProto.goGame }
    func supportsScore() -> Bool { game == LanProto.goGame }

    // MARK: - 哈希

    func hash() -> String {
        if game == LanProto.goGame {
            guard let g = go else { return "" }
            var text = "1|SZ=\(g.size)|M=\(moveNo)|T=\(g.turn == .black ? "B" : "W")|K=\(g.ko?.x ?? -1),\(g.ko?.y ?? -1)|"
            for y in 0..<g.size {
                if y > 0 { text.append("/") }
                for x in 0..<g.size {
                    text.append(String(g.board[y][x].rawValue))
                }
            }
            return LanProto.sha256Hex(text)
        }
        guard let g = xiangqi else { return "" }
        return LanProto.sha256Prefix8(Self.compatPositionKey(g) + "|M=\(moveNo)")
    }

    /// 与 Android `XiangqiGame.positionKey()` 逐字节一致：
    /// 空格 'a'，红方 'b'..'h'，黑方 'i'..'o'，末尾拼行棋方 1/2。
    static func compatPositionKey(_ g: XiangqiGame) -> String {
        var out = ""
        for y in 0..<XiangqiGame.rows {
            for x in 0..<XiangqiGame.cols {
                if let piece = g.board[y][x] {
                    let value = piece.color == .red ? piece.kind.rawValue + 1 : piece.kind.rawValue + 8
                    out.append(Character(UnicodeScalar(UInt8(97 + value))))
                } else {
                    out.append("a")
                }
            }
        }
        out.append(String(g.turn.rawValue))
        return out
    }

    // MARK: - 快照

    func snapshot() -> [String: Any] {
        var out: [String: Any]
        if game == LanProto.goGame, let g = go {
            var board = ""
            for y in 0..<g.size {
                if y > 0 { board.append("/") }
                for x in 0..<g.size { board.append(String(g.board[y][x].rawValue)) }
            }
            let moves: [[Any]] = g.history.map { move in
                [move.color == .black ? "B" : "W", move.point?.x ?? -1, move.point?.y ?? -1]
            }
            out = [
                "size": g.size,
                "komi": komi,
                "toMove": g.turn == .black ? "B" : "W",
                "ko": [g.ko?.x ?? -1, g.ko?.y ?? -1],
                "board": board,
                "moves": moves
            ]
        } else if let g = xiangqi {
            let moves: [[Any]] = g.history.map { move in
                [move.uci, move.from.x, move.from.y, move.to.x, move.to.y]
            }
            out = [
                "size": XiangqiGame.cols,
                "fen": g.fen,
                "toMove": g.turn == .red ? "R" : "B",
                "result": xiangqiResultCode(g),
                "endReason": g.endReason,
                "moves": moves
            ]
        } else {
            out = [:]
        }
        out["gameId"] = matchId
        out["game"] = game
        out["moveNo"] = moveNo
        out["consecutivePasses"] = consecutivePasses
        out["hash"] = hash()
        return out
    }

    private func xiangqiResultCode(_ g: XiangqiGame) -> Int {
        if g.isDraw { return 3 }
        return g.result?.rawValue ?? 0
    }

    func restore(_ p: [String: Any]) -> Bool {
        let restoredSize = LanProto.int(p, "size", game == LanProto.goGame ? LanProto.goSize : XiangqiGame.cols)
        if game == LanProto.goGame {
            let g = GoGame(size: restoredSize)
            komi = LanProto.double(p, "komi", LanProto.goKomi)
            g.komi = komi
            if let moves = p["moves"] as? [[Any]] {
                for one in moves {
                    guard one.count >= 3 else { return false }
                    let x = Self.number(one[1])
                    let y = Self.number(one[2])
                    if x < 0 {
                        g.pass()
                    } else if g.play(x, y) == nil {
                        return false
                    }
                }
            }
            go = g
            size = g.size
        } else {
            let g = XiangqiGame()
            let moves = (p["moves"] as? [[Any]]) ?? []
            if !moves.isEmpty {
                for one in moves {
                    if one.count >= 5 {
                        if !g.play(from: GoPoint(x: Self.number(one[1]), y: Self.number(one[2])),
                                   to: GoPoint(x: Self.number(one[3]), y: Self.number(one[4]))) {
                            return false
                        }
                    } else if let uci = one.first as? String, !g.playUci(uci) {
                        return false
                    }
                }
            } else if let fen = p["fen"] as? String, !fen.isEmpty {
                if !g.loadFen(fen) { return false }
            }
            xiangqi = g
            size = XiangqiGame.cols
        }
        moveNo = LanProto.int(p, "moveNo", moveCount())
        consecutivePasses = LanProto.int(p, "consecutivePasses", 0)
        let expected = LanProto.string(p, "hash")
        return expected.isEmpty || expected == hash()
    }

    private static func number(_ value: Any) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? -1 }
        return -1
    }

    // MARK: - 裁决

    func applyAuthority(seat: Int, move: [String: Any], expectMoveNo: Int, hashBefore: String) -> LanApplyResult {
        var r = LanApplyResult()
        r.nextTurn = turn()
        if expectMoveNo > 0, expectMoveNo != moveNo + 1 {
            r.code = "E_STALE_MOVE"
            r.message = "手数不同步（期望第 \(moveNo + 1) 手）"
            return r
        }
        if seat != turn() {
            r.code = "E_OUT_OF_TURN"
            r.message = "还没轮到你落子"
            return r
        }
        if !hashBefore.isEmpty, hashBefore != hash() {
            r.code = "E_HASH_MISMATCH"
            r.message = "棋盘状态不同步"
            return r
        }
        r = apply(seat: seat, move: move)
        guard r.ok else { return r }
        moveNo += 1
        consecutivePasses = r.pass ? consecutivePasses + 1 : 0
        r.moveNo = moveNo
        r.hash = hash()
        r.nextTurn = turn()
        return r
    }

    private func apply(seat: Int, move: [String: Any]) -> LanApplyResult {
        var r = LanApplyResult()
        r.nextTurn = turn()
        guard seat == turn() else {
            r.code = "E_OUT_OF_TURN"
            r.message = "还没轮到这一方"
            return r
        }
        if game == LanProto.goGame {
            guard let g = go else { return r }
            if LanProto.bool(move, "pass") {
                g.pass()
                r.ok = true
                r.pass = true
                r.nextTurn = turn()
                return r
            }
            let x = LanProto.int(move, "x", -1)
            let y = LanProto.int(move, "y", -1)
            if x < 0 || y < 0 || x >= g.size || y >= g.size {
                r.code = "E_OCCUPIED"
                r.message = "落点超出棋盘"
                return r
            }
            if g.board[y][x] != .empty {
                r.code = "E_OCCUPIED"
                r.message = "这里已经有子了"
                return r
            }
            guard let played = g.play(x, y) else {
                let isKo = x == g.ko?.x && y == g.ko?.y
                r.code = isKo ? "E_KO" : "E_SUICIDE"
                r.message = isKo ? "打劫，暂时不能立即提回" : "禁入点"
                return r
            }
            r.ok = true
            r.x = x
            r.y = y
            r.captured = played.captured.count
            r.nextTurn = turn()
            return r
        }

        guard let g = xiangqi else { return r }
        let fx = LanProto.int(move, "fx", -1)
        let fy = LanProto.int(move, "fy", -1)
        let tx = LanProto.int(move, "tx", -1)
        let ty = LanProto.int(move, "ty", -1)
        if fx < 0 || fy < 0 || tx < 0 || ty < 0
            || fx >= XiangqiGame.cols || tx >= XiangqiGame.cols
            || fy >= XiangqiGame.rows || ty >= XiangqiGame.rows {
            r.code = "E_ILLEGAL_MOVE"
            r.message = "落点超出棋盘"
            return r
        }
        let captured = g.piece(at: tx, ty) != nil ? 1 : 0
        if !g.play(from: GoPoint(x: fx, y: fy), to: GoPoint(x: tx, y: ty)) {
            r.code = "E_ILLEGAL_MOVE"
            r.message = g.illegalReason(from: GoPoint(x: fx, y: fy), to: GoPoint(x: tx, y: ty))
            return r
        }
        r.ok = true
        r.fx = fx
        r.fy = fy
        r.tx = tx
        r.ty = ty
        r.captured = captured
        r.nextTurn = turn()
        return r
    }

    func applyAck(_ ack: [String: Any], ackMoveNo: Int, expectedHash: String) -> Bool {
        guard ackMoveNo == moveNo + 1 else { return false }
        if game == LanProto.goGame {
            guard let g = go else { return false }
            if LanProto.bool(ack, "pass") {
                g.pass()
            } else if g.play(LanProto.int(ack, "x", -1), LanProto.int(ack, "y", -1)) == nil {
                return false
            }
        } else {
            guard let g = xiangqi else { return false }
            if !g.play(from: GoPoint(x: LanProto.int(ack, "fx", -1), y: LanProto.int(ack, "fy", -1)),
                       to: GoPoint(x: LanProto.int(ack, "tx", -1), y: LanProto.int(ack, "ty", -1))) {
                return false
            }
        }
        moveNo = ackMoveNo
        consecutivePasses = LanProto.bool(ack, "pass") ? consecutivePasses + 1 : 0
        return expectedHash.isEmpty || expectedHash == hash()
    }

    func undo(_ count: Int) -> Int {
        var done = 0
        if game == LanProto.goGame {
            guard let g = go else { return 0 }
            while done < count, g.canUndo {
                g.undo()
                done += 1
            }
        } else {
            guard let g = xiangqi else { return 0 }
            while done < count {
                guard g.undo() != nil else { break }
                done += 1
            }
        }
        if done > 0 {
            moveNo = max(0, moveNo - done)
            consecutivePasses = 0
        }
        return done
    }

    func movePayload(seat: Int, move: [String: Any], hashBefore: String) -> [String: Any] {
        var p: [String: Any] = [:]
        if game == LanProto.goGame {
            p["pass"] = LanProto.bool(move, "pass")
            p["x"] = LanProto.int(move, "x", -1)
            p["y"] = LanProto.int(move, "y", -1)
        } else {
            let fx = LanProto.int(move, "fx", -1)
            let fy = LanProto.int(move, "fy", -1)
            let tx = LanProto.int(move, "tx", -1)
            let ty = LanProto.int(move, "ty", -1)
            p["fx"] = fx
            p["fy"] = fy
            p["tx"] = tx
            p["ty"] = ty
            p["uci"] = XiangqiGame.Move(from: GoPoint(x: fx, y: fy), to: GoPoint(x: tx, y: ty)).uci
        }
        if !hashBefore.isEmpty { p["hashBefore"] = hashBefore }
        return p
    }

    struct MoveInfo {
        var seat = 1
        var fx = -1, fy = -1, tx = -1, ty = -1
        var pass = false
        var captured = 0
        var text = ""
    }

    func lastMove() -> MoveInfo? {
        if game == LanProto.goGame {
            guard let g = go, let m = g.history.last else { return nil }
            var info = MoveInfo()
            info.seat = m.color == .black ? 1 : 2
            info.pass = m.point == nil
            info.fx = m.point?.x ?? -1
            info.fy = m.point?.y ?? -1
            info.captured = m.captured.count
            info.text = m.point == nil ? "停一手" : g.toGtp(m.point!.x, m.point!.y)
            return info
        }
        guard let g = xiangqi, let m = g.history.last else { return nil }
        var info = MoveInfo()
        info.seat = m.color == .red ? 1 : 2
        info.fx = m.from.x
        info.fy = m.from.y
        info.tx = m.to.x
        info.ty = m.to.y
        info.captured = m.captured == nil ? 0 : 1
        info.text = g.notation(m)
        return info
    }

    // MARK: - 结果

    func result() -> [String: Any]? {
        guard game == LanProto.xiangqiGame, let g = xiangqi, g.isOver else { return nil }
        let code = g.isDraw ? "draw" : colorChar(g.result?.rawValue ?? 1)
        return ["result": code, "detail": g.endReason, "reason": "rule"]
    }

    func resultByResign(_ resignSeat: Int) -> [String: Any] {
        let winner = 3 - resignSeat
        let detail = "\(colorName(resignSeat))方认输，\(colorName(winner))方" +
            (game == LanProto.goGame ? "中盘胜" : "胜")
        if game == LanProto.xiangqiGame { xiangqi?.resign(resignSeat == 1 ? .red : .black) }
        var out: [String: Any] = ["result": colorChar(winner), "detail": detail, "reason": "resign"]
        if game == LanProto.goGame {
            out["result"] = colorChar(winner) + "+R"
            out["blackScore"] = -1
            out["whiteScore"] = -1
        }
        return out
    }

    func resultByTimeout(_ timeoutSeat: Int) -> [String: Any] {
        let winner = 3 - timeoutSeat
        let detail = "\(colorName(timeoutSeat))方超时，\(colorName(winner))方" +
            (game == LanProto.goGame ? "胜" : "胜")
        if game == LanProto.xiangqiGame { xiangqi?.resign(timeoutSeat == 1 ? .red : .black) }
        var out: [String: Any] = ["result": colorChar(winner), "detail": detail, "reason": "timeout"]
        if game == LanProto.goGame {
            out["result"] = colorChar(winner) + "+T"
            out["blackScore"] = -1
            out["whiteScore"] = -1
        }
        return out
    }

    func resultByDisconnect(_ lostSeat: Int) -> [String: Any] {
        let winner = 3 - lostSeat
        let detail = "\(colorName(lostSeat))方断线，\(colorName(winner))方" +
            (game == LanProto.goGame ? "中盘胜" : "胜")
        if game == LanProto.xiangqiGame { xiangqi?.resign(lostSeat == 1 ? .red : .black) }
        var out: [String: Any] = ["result": colorChar(winner), "detail": detail, "reason": "disconnect"]
        if game == LanProto.goGame {
            out["result"] = colorChar(winner) + "+R"
            out["blackScore"] = -1
            out["whiteScore"] = -1
        }
        return out
    }

    func scoreResult() -> [String: Any]? {
        guard game == LanProto.goGame, let g = go else { return nil }
        let s = g.chineseScore()
        let white = s.white + komi
        let diff = abs(s.black - white)
        let code: String
        let detail: String
        if diff < 0.5 {
            code = "draw"
            detail = String(format: "和棋\n黑 %.0f : 白 %.0f（含贴目 %.1f）", s.black, white, komi)
        } else if s.black > white {
            code = String(format: "B+%.1f", diff)
            detail = String(format: "黑胜 %.1f 目\n黑 %.0f : 白 %.0f（含贴目 %.1f）", diff, s.black, white, komi)
        } else {
            code = String(format: "W+%.1f", diff)
            detail = String(format: "白胜 %.1f 目\n黑 %.0f : 白 %.0f（含贴目 %.1f）", diff, s.black, white, komi)
        }
        return ["result": code, "detail": detail, "reason": "score",
                "blackScore": s.black, "whiteScore": white]
    }

    func colorChar(_ seat: Int) -> String {
        LanProto.colorChar(game: game, seat: seat)
    }

    func seatFromChar(_ text: String) -> Int {
        LanProto.seatOfColorChar(game: game, text) ?? 2
    }

    func colorName(_ seat: Int) -> String {
        game == LanProto.goGame ? LanProto.goColorName(seat) : LanProto.xqColorName(seat)
    }
}

/// 联机运行时单例：持有 Host/Guest、权威会话与时钟，跨页面存活。
/// 所有棋局修改都在主线程串行执行。
@MainActor
final class LanHub: ObservableObject {
    enum State: Int {
        case idle = 0, hosting, connecting, lobby, playing, finished, error
    }
    enum Role: String {
        case host, guest, none
    }

    static let shared = LanHub()

    @Published private(set) var state: State = .idle
    @Published private(set) var rooms: [LanRoom] = []
    @Published private(set) var roomCode = ""
    @Published var localName = "棋友"
    @Published private(set) var opponentName = "对手"
    @Published private(set) var gameId = ""
    @Published private(set) var myColor = 1
    @Published private(set) var hostColor = 1
    @Published private(set) var mainSec = 1200
    @Published private(set) var byoYomiSec = 30
    @Published private(set) var periods = 3
    /// 房间规则：是否允许落点 / 可吃子提示。房主建房时确定，随房间下发，客机不得自行修改。
    @Published private(set) var hintsEnabled = true
    @Published private(set) var hostAddress = ""
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var linkDown = false
    @Published private(set) var pendingMove = false
    /// 房主侧是否有客机接入（主线程镜像，避免跨队列读取 LanHost 内部状态）
    @Published private(set) var guestPresent = false
    /// 围棋双方连续各停一手后为 true：只进入数子确认，不直接终局
    @Published private(set) var scorePending = false
    @Published private(set) var resultCode = ""
    @Published private(set) var resultDetail = ""
    @Published private(set) var resultReason = ""
    @Published private(set) var lastError = ""
    @Published private(set) var notice = ""
    @Published private(set) var incomingUndoFrom: String?
    @Published private(set) var clockTick = 0
    @Published private(set) var boardVersion = 0

    private(set) var role: Role = .none
    private(set) var session: LanGameSession?
    private var clock: LanClock?
    private var host: LanHost?
    private var client: LanClient?
    private var discovery: LanDiscovery?
    private var queryResponder: LanQueryResponder?

    private var guestClock: [String: Any]?
    private var guestClockAt: Int64 = 0
    private var clockFrozen = false

    private var pendingUndoFrom: String?
    private var pendingUndoCount = 1
    private var outgoingUndo = false
    /// 待房主确认的数子结果
    private var pendingScore: [String: Any]?

    private var ticker: Timer?
    private var linkTimer: Timer?
    private var graceTask: DispatchWorkItem?
    private var reconnectTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    private var lastRecvAt: Int64 = 0
    private var lastPingAt: Int64 = 0
    private var lastClockPush: Int64 = 0
    private var linkEpoch = 0
    private var attemptSeq = 0
    /// 进程处于后台时系统会挂起本 App，重连循环与宽限计时都不可信。
    private var appInBackground = false

    private var joinAck = false
    private var joinRejected = false
    private var joinRejectMessage = ""
    private var joinRejectCode = ""
    private var joinCloseReason = ""

    private var lastHostIp = ""
    private var lastHostPort: UInt16 = 0
    private let clientId = UUID().uuidString
    private let appVersion = "1.0.7"

    private init() {}

    // MARK: - 只读展示

    var isHost: Bool { role == .host }
    var isGuest: Bool { role == .guest }
    var isPlaying: Bool { state == .playing }
    var boardSize: Int { session?.size ?? LanProto.goSize }
    var moveNo: Int { session?.moveNo ?? 0 }
    var turn: Int { session?.turn() ?? 1 }
    var isMyTurn: Bool { session?.turn() == myColor }
    var komi: Double { session?.komi ?? LanProto.goKomi }
    var timerEnabled: Bool { mainSec > 0 }
    var supportsScore: Bool { session?.supportsScore() ?? (gameId == LanProto.goGame) }
    var supportsPass: Bool { session?.supportsPass() ?? (gameId == LanProto.goGame) }
    var hasGuest: Bool { guestPresent }
    var gameLabel: String { LanProto.gameName(gameId) }

    var goGame: GoGame? { session?.go }
    var xiangqiGame: XiangqiGame? { session?.xiangqi }
    var goBoard: [[GoColor]] { session?.go?.board ?? [] }
    var xiangqiBoard: [[XiangqiGame.Piece?]] { session?.xiangqi?.board ?? [] }
    var koPoint: GoPoint? { session?.go?.ko }
    var lastMoveGo: GoPoint? { session?.go?.history.last?.point }
    var lastMoveXiangqi: XiangqiGame.Move? { session?.xiangqi?.history.last }

    var resultText: String {
        LanResultText.text(gameId: gameId, code: resultCode, reason: resultReason, detail: resultDetail)
    }

    func colorChar(_ seat: Int) -> String {
        LanProto.colorChar(game: gameId, seat: seat)
    }

    func colorName(_ seat: Int) -> String {
        gameId == LanProto.xiangqiGame ? LanProto.xqColorName(seat) : LanProto.goColorName(seat)
    }

    func myColorName() -> String { colorName(myColor) }

    var lastMoveText: String { session?.lastMove()?.text ?? "" }

    // MARK: - 发现

    func startBrowsing(game: String) {
        let d = LanDiscovery()
        d.gameFilter = game
        d.onRooms = { [weak self] list in
            Task { @MainActor in self?.rooms = list }
        }
        d.onError = { [weak self] message in
            Task { @MainActor in self?.lastError = message }
        }
        discovery = d
        d.start()
    }

    func stopBrowsing() {
        discovery?.stop()
        discovery = nil
        rooms = []
    }

    // MARK: - 建房

    func hostRoom(game: String, name: String, color: Int,
                  mainSec: Int, byoYomiSec: Int, periods: Int,
                  hints: Bool = true) {
        // 旧监听器的 socket 释放是异步的；先等它彻底停掉再绑端口，
        // 否则新房间会被迫顺延到 41235、41236……（曾一路漂到 41244）。
        let previousHost = host
        stop()
        role = .host
        gameId = game == LanProto.xiangqiGame ? LanProto.xiangqiGame : LanProto.goGame
        localName = Self.safe(name, "棋友")
        hostColor = color == 2 ? 2 : 1
        myColor = hostColor
        roomCode = LanProto.newRoomCode()
        self.mainSec = max(0, mainSec)
        self.byoYomiSec = max(0, byoYomiSec)
        self.periods = max(1, periods)
        self.hintsEnabled = hints
        scorePending = false
        pendingScore = nil

        let newSession = LanGameSession(room: roomCode, game: gameId)
        newSession.reset(komi: gameId == LanProto.goGame ? LanProto.goKomi : 0)
        session = newSession
        clock = LanClock(mainSec: self.mainSec, byoYomiSec: self.byoYomiSec, periods: self.periods)

        let newHost = LanHost(roomCode: roomCode, gameId: gameId, size: newSession.size,
                              hintsEnabled: hints)
        host = newHost
        // 「只填房号」加入的兜底通道：UDP 广播查询，回包带真实端口
        let responder = LanQueryResponder(room: roomCode, game: gameId, iid: newHost.iid)
        queryResponder = responder
        responder.start()
        newHost.onReady = { [weak self, weak newHost] port, addr in
            Task { @MainActor in
                guard let self, let newHost, self.host === newHost else { return }
                self.port = port
                self.hostAddress = addr.isEmpty ? "\(port)" : "\(addr):\(port)"
                self.state = .hosting
                self.queryResponder?.update(port: port, addr: addr)
                self.updateProbePayload()
            }
        }
        newHost.onError = { [weak self, weak newHost] message in
            Task { @MainActor in
                guard let self, let newHost, self.host === newHost else { return }
                // 一个端口都没绑上：状态必须落到 error，并把地址清空，
                // 避免界面继续展示一个实际没有监听的 “IP:端口”。
                self.lastError = message
                self.notice = message
                self.hostAddress = ""
                self.port = 0
                if self.state == .hosting { self.state = .error }
            }
        }
        newHost.onMessage = { [weak self] msg in
            Task { @MainActor in self?.onHostMessage(msg) }
        }
        newHost.onGuestChanged = { [weak self] connected in
            Task { @MainActor in self?.onGuestChanged(connected) }
        }
        if let previousHost {
            previousHost.stop { [weak self, weak newHost] in
                Task { @MainActor in
                    guard let self, let newHost, self.host === newHost else { return }
                    newHost.start()
                }
            }
        } else {
            newHost.start()
        }
        state = .hosting
        boardVersion += 1
        updateProbePayload()
    }

    private func updateProbePayload() {
        guard let host else { return }
        host.setProbePayload([
            "room": roomCode,
            "game": gameId,
            "iid": host.iid,
            "pid": host.pid,
            "ts": LanProto.nowMs(),
            "hints": hintsEnabled ? 1 : 0,
            "state": state == .playing ? "playing" : "waiting"
        ])
    }

    private func onGuestChanged(_ connected: Bool) {
        guestPresent = connected
        if connected { return }
        if state == .playing {
            onHostLinkLost("对手连接已断开")
        } else if state == .lobby {
            state = .hosting
            opponentName = "对手"
        }
    }

    // MARK: - 加入

    func joinRoom(candidates: [String], code: String, name: String, game: String?) {
        stop()
        role = .guest
        localName = Self.safe(name, "棋友")
        roomCode = LanProto.normalizeRoomCode(code)
        gameId = (game ?? "").trimmingCharacters(in: .whitespaces)
        state = .connecting
        hostAddress = candidates.first ?? ""
        let list = candidates
        connectTask = Task { await self.connectLoop(list) }
    }

    func joinRoom(room: LanRoom, name: String) {
        joinRoom(candidates: ["\(room.host):\(room.port)"], code: room.code, name: name, game: room.game)
    }

    /// 只填房号也能加入：
    /// 1. 已发现列表里有同房号 → 直接用它的真实地址；
    /// 2. 填了地址 → 显式端口直接连，否则用 UDP 广播补真实端口，再退回端口区间扫描；
    /// 3. 什么都没填 → UDP 广播按房号定向查询；查不到给明确提示，不干等。
    func joinByInput(code raw: String, address: String, name: String, game: String?) {
        let code = LanProto.normalizeRoomCode(raw)
        let text = address.trimmingCharacters(in: .whitespaces)

        if let room = rooms.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
            joinRoom(candidates: ["\(room.host):\(room.port)"], code: code, name: name, game: game)
            return
        }
        if !text.isEmpty {
            let base = manualCandidates(text, code: code)
            if Self.explicitPort(text) != nil {
                joinRoom(candidates: base, code: code, name: name, game: game)
                return
            }
            joinWithLookup(code: code, address: text, base: base, name: name, game: game)
            return
        }
        joinWithLookup(code: code, address: "", base: [], name: name, game: game)
    }

    private func joinWithLookup(code: String, address: String, base: [String],
                                name: String, game: String?) {
        stop()
        role = .guest
        localName = Self.safe(name, "棋友")
        roomCode = code
        gameId = (game ?? "").trimmingCharacters(in: .whitespaces)
        state = .connecting
        hostAddress = ""
        connectTask = Task {
            let found = await LanRoomQuery.lookup(code: code, timeout: address.isEmpty ? 2.5 : 1.8)
            guard self.state == .connecting else { return }
            var list: [String] = []
            if address.isEmpty {
                list = found
            } else {
                let ip = Self.hostOnly(address)
                for item in found where ip.isEmpty || item.hasPrefix(ip + ":") {
                    list.append(item)
                }
                list.append(contentsOf: base)
            }
            var seen = Set<String>()
            let unique = list.filter { seen.insert($0).inserted }
            guard !unique.isEmpty else {
                self.failJoin("未找到房号 \(code) 的房间，请确认双方在同一网络（或让房主把「地址」发给你）")
                return
            }
            await self.connectLoop(unique)
        }
    }

    private func connectLoop(_ candidates: [String]) async {
        var lastReason = "没有可用的房主地址"
        // 手动加入可能要在 41234–41244 之间扫描，给一个总时限避免干等很久
        let deadline = Date().addingTimeInterval(20)
        for candidate in candidates {
            if state != .connecting { return }
            if Date() > deadline {
                lastReason = "连接超时，已尝试部分地址/端口"
                break
            }
            guard let (ip, port) = Self.splitHostPort(candidate) else {
                lastReason = "地址格式错误：\(candidate)"
                continue
            }
            hostAddress = "\(ip):\(port)"
            resetJoinWait()
            attemptSeq += 1
            let seq = attemptSeq
            let newClient = LanClient()
            client = newClient
            newClient.onMessage = { [weak self, weak newClient] msg in
                Task { @MainActor in
                    guard let self, let newClient, self.attemptSeq == seq, self.client === newClient else { return }
                    self.onGuestMessage(msg)
                }
            }
            newClient.onClosed = { [weak self, weak newClient] reason in
                Task { @MainActor in
                    guard let self, let newClient, self.attemptSeq == seq, self.client === newClient else { return }
                    self.onClientClosed(reason)
                }
            }
            newClient.connect(host: ip, port: port)

            var payload: [String: Any] = [
                "protocolVersion": LanProto.version,
                "roomCode": roomCode,
                "deviceName": localName,
                "platform": "ios",
                "appVersion": appVersion,
                "clientId": clientId
            ]
            if !gameId.isEmpty { payload["game"] = gameId }
            if !newClient.send(LanProto.message(LanMsg.hello, room: roomCode, from: "guest", payload: payload)) {
                lastReason = "向 \(ip):\(port) 发送 hello 失败"
                newClient.close()
                continue
            }
            let why = await waitHello(timeout: 6)
            if joinAck {
                lastHostIp = ip
                lastHostPort = port
                return
            }
            attemptSeq += 1
            if client === newClient { client = nil }
            newClient.close()
            if state != .connecting { return }
            if joinRejected {
                failJoin(joinRejectMessage.isEmpty ? "房主拒绝加入" : joinRejectMessage)
                return
            }
            lastReason = why.isEmpty ? "连接 \(ip):\(port) 后未收到握手回应" : why
        }
        failJoin("连接失败：\(lastReason)")
    }

    private func waitHello(timeout: TimeInterval) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if joinAck || joinRejected { return "" }
            if !joinCloseReason.isEmpty { return joinCloseReason }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return "等待 hello_ack 超时（\(Int(timeout * 1000))ms）"
    }

    private func resetJoinWait() {
        joinAck = false
        joinRejected = false
        joinRejectMessage = ""
        joinRejectCode = ""
        joinCloseReason = ""
    }

    private func failJoin(_ message: String) {
        guard state == .connecting else { return }
        state = .error
        lastError = message
        notice = message
    }

    private func onClientClosed(_ reason: String) {
        pendingMove = false
        if !joinAck && !joinRejected { joinCloseReason = reason.isEmpty ? "连接已断开" : reason }
        if state == .playing {
            onClientLinkLost(reason.isEmpty ? "连接已断开" : reason)
        } else if state == .lobby {
            // 已进入房间但还没开局时断线：不要停在「等待房主开局」的死界面
            state = .error
            lastError = "与房主的连接已断开：\(reason)"
            notice = lastError
        }
    }

    // MARK: - 开局

    func startGame() {
        guard isHost, state == .lobby, hasGuest, let newSession = session, let newHost = host else { return }
        newSession.reset(komi: gameId == LanProto.goGame ? LanProto.goKomi : 0)
        scorePending = false
        pendingScore = nil
        clock = LanClock(mainSec: mainSec, byoYomiSec: byoYomiSec, periods: periods)
        let timed = clock?.active ?? false
        if timed {
            clock?.start(firstColor: 0)
            lastClockPush = LanProto.uptimeMs()
        }

        var payload: [String: Any] = [
            "game": newSession.game,
            "gameId": newSession.matchId,
            "size": newSession.size,
            "komi": newSession.komi,
            "handicap": 0,
            "handicapPoints": [],
            "ruleset": gameId == LanProto.goGame ? "chinese-simple-ko" : "xiangqi",
            "toMove": newSession.colorChar(newSession.turn()),
            "seats": [
                ["seat": 0, "name": localName, "color": newSession.colorChar(hostColor), "kind": "human"],
                ["seat": 1, "name": opponentName, "color": newSession.colorChar(3 - hostColor), "kind": "human"]
            ],
            "timeControl": [
                "mode": timed ? "byoyomi" : "none",
                "mainSec": mainSec,
                "byoYomiSec": byoYomiSec,
                "periods": periods,
                "incrementSec": 0
            ],
            "startAtHostMs": LanProto.nowMs(),
            "hints": hintsEnabled ? 1 : 0
        ]

        guard newHost.send(LanProto.message(LanMsg.gameStart, room: roomCode, from: "host", payload: payload)) else {
            notice = "发送开局消息失败，请让对手重新加入房间"
            return
        }
        state = .playing
        if timed { startTicker() }
        lastRecvAt = LanProto.uptimeMs()
        lastPingAt = 0
        startLinkWatch()
        boardVersion += 1
        clockTick += 1
        updateProbePayload()
    }

    // MARK: - 落子

    func requestMove(x: Int, y: Int) -> Bool {
        guard state == .playing, gameId == LanProto.goGame else { return false }
        return submitMove(["pass": false, "x": x, "y": y])
    }

    func requestPass() -> Bool {
        guard state == .playing, !scorePending, gameId == LanProto.goGame else { return false }
        return submitMove(["pass": true, "x": -1, "y": -1])
    }

    func requestXiangqiMove(fx: Int, fy: Int, tx: Int, ty: Int) -> Bool {
        guard state == .playing, gameId == LanProto.xiangqiGame else { return false }
        return submitMove(["fx": fx, "fy": fy, "tx": tx, "ty": ty])
    }

    @discardableResult
    private func submitMove(_ move: [String: Any]) -> Bool {
        if linkDown {
            notice = "连接中断，正在重连，请稍候…"
            return false
        }
        if scorePending {
            notice = "已进入数子确认，等待房主确认"
            return false
        }
        guard let session else { return false }
        if session.turn() != myColor {
            notice = "还没轮到你走棋"
            return false
        }
        if isHost {
            return hostApply(seat: myColor, move: move)
        }
        if pendingMove { return false }
        var payload = session.movePayload(seat: myColor, move: move, hashBefore: session.hash())
        payload["moveNo"] = session.moveNo + 1
        payload["color"] = colorChar(myColor)
        guard sendToHost(LanProto.message(LanMsg.move, room: roomCode, from: "guest", payload: payload)) else {
            notice = "落子发送失败，请检查连接"
            return false
        }
        pendingMove = true
        return true
    }

    private func hostApply(seat: Int, move: [String: Any]) -> Bool {
        guard let session else { return false }
        let r = session.applyAuthority(seat: seat, move: move, expectMoveNo: 0, hashBefore: "")
        guard r.ok else {
            notice = r.message
            return false
        }
        if let clock, clock.active {
            clock.onMove(seat - 1)
            if clock.timedOutColor >= 0 {
                hostTimeout(clock.timedOutColor)
                return true
            }
        }
        sendAck(r)
        boardVersion += 1
        afterMove()
        return true
    }

    private func sendAck(_ r: LanApplyResult) {
        guard let session else { return }
        var payload: [String: Any] = [
            "moveNo": r.moveNo,
            "pass": r.pass,
            "x": r.x,
            "y": r.y,
            "fx": r.fx,
            "fy": r.fy,
            "tx": r.tx,
            "ty": r.ty,
            "captured": r.captured,
            "nextTurn": session.colorChar(r.nextTurn),
            "hash": r.hash
        ]
        if let clock, clock.active {
            payload["clock"] = clock.snapshot(moveNo: session.moveNo)
            clockTick += 1
        }
        host?.send(LanProto.message(LanMsg.moveAck, room: roomCode, from: "host", payload: payload))
    }

    private func afterMove() {
        guard let session else { return }
        playMoveSound()
        if let result = session.result() {
            hostFinishPayload(result)
            return
        }
        if session.supportsScore(), session.consecutivePasses >= 2 {
            // 连续两次停一手只进入数子确认，避免「双方各停一手就立刻判终局」
            hostScorePending(session.scoreResult())
        }
    }

    /// 双方连续各停一手：把数子结果发给双方预览，等待房主确认后才真正结束。
    private func hostScorePending(_ res: [String: Any]?) {
        guard let res, let session, !scorePending else { return }
        pendingScore = res
        scorePending = true
        resultCode = LanProto.string(res, "result")
        resultDetail = LanProto.string(res, "detail", "双方各停一手")
        resultReason = LanProto.string(res, "reason")
        notice = "双方各停一手，请房主确认数子结果"
        var payload: [String: Any] = [
            "game": session.game,
            "moveNo": session.moveNo,
            "komi": session.komi
        ]
        for (key, value) in res { payload[key] = value }
        host?.send(LanProto.message(LanMsg.scorePending, room: roomCode, from: "host", payload: payload))
        boardVersion += 1
        clockTick += 1
    }

    /// 房主确认数子后才广播 game_over。
    func confirmScore() {
        guard isHost, scorePending, let res = pendingScore else { return }
        scorePending = false
        pendingScore = nil
        hostFinishPayload(res)
    }

    // MARK: - 悔棋

    func requestUndo() {
        guard state == .playing, let session, session.moveNo > 0 else { return }
        if pendingUndoFrom != nil || outgoingUndo { return }
        pendingUndoFrom = isHost ? Role.host.rawValue : Role.guest.rawValue
        pendingUndoCount = 1
        outgoingUndo = true
        let payload: [String: Any] = ["count": 1, "moveNo": session.moveNo]
        send(LanProto.message(LanMsg.undoRequest, room: roomCode,
                              from: isHost ? "host" : "guest", payload: payload))
        notice = "已发送悔棋请求"
    }

    func respondUndo(accept: Bool) {
        guard pendingUndoFrom != nil else { return }
        pendingUndoFrom = nil
        incomingUndoFrom = nil
        if isHost {
            if accept {
                hostUndo(pendingUndoCount)
            } else {
                host?.send(LanProto.message(LanMsg.undoResponse, room: roomCode,
                                            from: "host", payload: ["accept": false]))
            }
        } else {
            sendToHost(LanProto.message(LanMsg.undoResponse, room: roomCode,
                                        from: "guest", payload: ["accept": accept]))
            if !accept { notice = "已拒绝悔棋" }
        }
    }

    private func hostUndo(_ count: Int) {
        guard let session else { return }
        // 悔棋改变了局面，之前的数子预览作废，避免确认后按旧比分结束
        scorePending = false
        pendingScore = nil
        session.undo(max(1, count))
        if let clock { clock.setTurn(session.turn() == 1 ? 0 : 1) }
        let payload: [String: Any] = [
            "moveNo": session.moveNo,
            "hash": session.hash(),
            "snapshot": session.snapshot()
        ]
        host?.send(LanProto.message(LanMsg.undoApplied, room: roomCode, from: "host", payload: payload))
        boardVersion += 1
        clockTick += 1
    }

    // MARK: - 认输 / 数子

    func resign() {
        guard state == .playing else { return }
        if isHost {
            hostEndByResign(.host)
        } else {
            sendToHost(LanProto.message(LanMsg.resign, room: roomCode, from: "guest",
                                        payload: ["by": colorChar(myColor)]))
        }
    }

    func requestScore() {
        guard state == .playing, let session else { return }
        if scorePending {
            // 待确认阶段点「数子」等于房主确认
            confirmScore()
            return
        }
        guard session.supportsScore() else {
            notice = "该棋种按规则自动判定胜负"
            return
        }
        guard isHost else {
            notice = "数子由房主结算"
            return
        }
        hostFinishPayload(session.scoreResult())
    }

    private func hostEndByResign(_ resigner: Role) {
        guard let session else { return }
        let seat = resigner == .host ? hostColor : 3 - hostColor
        hostFinishPayload(session.resultByResign(seat))
    }

    private func hostTimeout(_ colorIndex: Int) {
        guard let session else { return }
        hostFinishPayload(session.resultByTimeout(colorIndex == 0 ? 1 : 2))
    }

    private func hostFinishPayload(_ res: [String: Any]?) {
        guard let res, let session else { return }
        cancelGrace()
        stopLinkWatch()
        scorePending = false
        pendingScore = nil
        resultCode = LanProto.string(res, "result")
        resultDetail = LanProto.string(res, "detail", "对局结束")
        resultReason = LanProto.string(res, "reason")
        state = .finished
        stopTicker()
        var payload: [String: Any] = [
            "game": session.game,
            "moveNo": session.moveNo,
            "komi": session.komi
        ]
        for (key, value) in res { payload[key] = value }
        host?.send(LanProto.message(LanMsg.gameOver, room: roomCode, from: "host", payload: payload))
        playGameOverSound()
        boardVersion += 1
        updateProbePayload()
    }

    // MARK: - 收消息

    private func onHostMessage(_ msg: [String: Any]) {
        lastRecvAt = LanProto.uptimeMs()
        let type = LanProto.type(msg)
        let p = LanProto.payload(msg)
        switch type {
        case LanMsg.hello: onHello(p)
        case LanMsg.move: onGuestMove(p)
        case LanMsg.undoRequest:
            pendingUndoFrom = Role.guest.rawValue
            pendingUndoCount = LanProto.int(p, "count", 1)
            incomingUndoFrom = opponentName
        case LanMsg.undoResponse:
            if LanProto.bool(p, "accept") { hostUndo(pendingUndoCount) }
            pendingUndoFrom = nil
            outgoingUndo = false
        case LanMsg.resign: hostEndByResign(.guest)
        case LanMsg.syncRequest:
            if let session {
                host?.send(LanProto.message(LanMsg.snapshot, room: roomCode,
                                            from: "host", payload: session.snapshot()))
            }
        case LanMsg.ping: replyPong(p)
        case LanMsg.bye: notice = "对方已离开房间"
        default: break
        }
    }

    private func onGuestMessage(_ msg: [String: Any]) {
        lastRecvAt = LanProto.uptimeMs()
        let type = LanProto.type(msg)
        let p = LanProto.payload(msg)
        switch type {
        case LanMsg.helloAck:
            if LanProto.bool(p, "resumed") {
                if let snapshot = p["snapshot"] as? [String: Any] { _ = session?.restore(snapshot) }
                if let ck = p["clock"] as? [String: Any] {
                    guestClock = ck
                    guestClockAt = LanProto.uptimeMs()
                }
                clockFrozen = false
                linkDown = false
                state = .playing
                lastRecvAt = LanProto.uptimeMs()
                lastPingAt = 0
                joinAck = true
                pendingMove = false
                notice = "已重新连接，对局继续"
                boardVersion += 1
                clockTick += 1
                startLinkWatch()
                return
            }
            joinAck = true
            let game = LanProto.string(p, "game", LanProto.goGame)
            gameId = game == LanProto.xiangqiGame ? LanProto.xiangqiGame : LanProto.goGame
            let gid = LanProto.string(p, "gameId")
            let newSession = LanGameSession(room: roomCode, game: gameId, matchId: gid)
            newSession.size = LanProto.int(p, "size", newSession.size)
            newSession.komi = LanProto.double(p, "komi", newSession.komi)
            session = newSession
            myColor = newSession.seatFromChar(LanProto.string(p, "yourColor", "W"))
            opponentName = LanProto.string(p, "opponentName", "对手")
            hintsEnabled = LanProto.bool(p, "hints", true)
            scorePending = false
            pendingScore = nil
            if let code = p["room"] as? String, !code.isEmpty { roomCode = code }
            state = .lobby
            boardVersion += 1

        case LanMsg.helloReject:
            var message = LanProto.string(p, "message", "无法加入房间")
            let code = LanProto.string(p, "code")
            if !code.isEmpty { message = "[\(code)] \(message)" }
            joinRejected = true
            joinRejectMessage = message
            joinRejectCode = code

        case LanMsg.gameStart:
            let gid = LanProto.string(p, "gameId")
            let game = LanProto.string(p, "game", LanProto.goGame)
            let komi = LanProto.double(p, "komi", LanProto.goKomi)
            if session == nil || gid != session?.matchId || game != session?.game {
                session = LanGameSession(room: roomCode, game: game, matchId: gid)
            }
            gameId = session?.game ?? game
            session?.size = LanProto.int(p, "size", session?.size ?? boardSize)
            session?.reset(komi: komi)
            scorePending = false
            pendingScore = nil
            // 房间规则由房主下发，客机只读
            hintsEnabled = LanProto.bool(p, "hints", hintsEnabled)
            if let tc = p["timeControl"] as? [String: Any] {
                mainSec = LanProto.int(tc, "mainSec", 0)
                byoYomiSec = LanProto.int(tc, "byoYomiSec", byoYomiSec)
                periods = LanProto.int(tc, "periods", periods)
            } else {
                mainSec = 0
            }
            state = .playing
            if mainSec > 0 { startTicker() } else { stopTicker() }
            lastRecvAt = LanProto.uptimeMs()
            lastPingAt = 0
            scorePending = false
            pendingScore = nil
            startLinkWatch()
            boardVersion += 1
            clockTick += 1

        case LanMsg.moveAck:
            pendingMove = false
            applyAck(p)

        case LanMsg.moveReject:
            pendingMove = false
            if let snapshot = p["snapshot"] as? [String: Any] { _ = session?.restore(snapshot) }
            notice = LanProto.string(p, "message", "落子被拒绝")
            boardVersion += 1

        case LanMsg.snapshot:
            if session?.restore(p) == true { boardVersion += 1 }

        case LanMsg.undoRequest:
            pendingUndoFrom = Role.host.rawValue
            pendingUndoCount = LanProto.int(p, "count", 1)
            incomingUndoFrom = opponentName

        case LanMsg.undoResponse:
            pendingUndoFrom = nil
            outgoingUndo = false
            if !LanProto.bool(p, "accept") { notice = "房主拒绝悔棋" }

        case LanMsg.undoApplied:
            pendingUndoFrom = nil
            outgoingUndo = false
            // 悔棋撤销数子确认（房主已重新结算）
            scorePending = false
            if let snapshot = p["snapshot"] as? [String: Any] { _ = session?.restore(snapshot) }
            boardVersion += 1
            clockTick += 1

        case LanMsg.clock:
            guestClock = p
            guestClockAt = LanProto.uptimeMs()
            clockFrozen = false
            clockTick += 1

        case LanMsg.scorePending:
            resultCode = LanProto.string(p, "result")
            resultDetail = LanProto.string(p, "detail", "双方各停一手")
            resultReason = LanProto.string(p, "reason")
            scorePending = true
            notice = "双方各停一手，等待房主确认数子"
            boardVersion += 1
            clockTick += 1

        case LanMsg.gameOver:
            scorePending = false
            pendingScore = nil
            resultCode = LanProto.string(p, "result")
            resultDetail = LanProto.string(p, "detail", "对局结束")
            resultReason = LanProto.string(p, "reason")
            state = .finished
            linkDown = false
            stopLinkWatch()
            stopTicker()
            playGameOverSound()
            boardVersion += 1
            clockTick += 1

        case LanMsg.ping:
            replyPong(p)

        case LanMsg.bye:
            notice = "房主已离开房间"

        default:
            break
        }
    }

    private func onHello(_ p: [String: Any]) {
        guard let session else { return }
        if roomCode.caseInsensitiveCompare(LanProto.string(p, "roomCode")) != .orderedSame {
            sendHelloReject("E_ROOM_CODE", "房间码不对（本房间 \(roomCode)）")
            return
        }
        if LanProto.int(p, "protocolVersion", 0) != LanProto.version {
            sendHelloReject(LanMsg.eVersion, "版本不一致，请升级 App")
            return
        }
        let guestGame = LanProto.string(p, "game")
        if !guestGame.isEmpty, guestGame != session.game {
            sendHelloReject(LanMsg.eGameMismatch, "房主这局是\(gameLabel)，请重新选择房间")
            return
        }
        if LanProto.bool(p, "resume"), state != .playing {
            sendHelloReject("E_NO_GAME", "这局已结束，无法恢复")
            return
        }
        if state == .playing {
            let resume = LanProto.bool(p, "resume")
            let gid = LanProto.string(p, "gameId")
            if resume, gid == session.matchId {
                host?.markHandshaked()
                cancelGrace()
                linkDown = false
                lastRecvAt = LanProto.uptimeMs()
                lastPingAt = 0
                clock?.resume()
                opponentName = Self.safe(LanProto.string(p, "deviceName", opponentName), "对手")
                var ack: [String: Any] = [
                    "ok": true,
                    "resumed": true,
                    "game": session.game,
                    "gameId": session.matchId,
                    "size": session.size,
                    "komi": session.komi,
                    "moveNo": session.moveNo,
                    "yourColor": session.colorChar(3 - hostColor),
                    "opponentName": localName,
                    "hints": hintsEnabled ? 1 : 0,
                    "snapshot": session.snapshot()
                ]
                if let clock, clock.active { ack["clock"] = clock.snapshot(moveNo: session.moveNo) }
                host?.send(LanProto.message(LanMsg.helloAck, room: roomCode, from: "host", payload: ack))
                notice = "对手已重新连接，计时继续"
                boardVersion += 1
                clockTick += 1
                return
            }
            sendHelloReject("E_ALREADY_PLAYING", "房间已开局")
            return
        }
        host?.markHandshaked()
        opponentName = Self.safe(LanProto.string(p, "deviceName", "对手"), "对手")
        let guestColor = 3 - hostColor
        var ack: [String: Any] = [
            "ok": true,
            "game": session.game,
            "gameId": session.matchId,
            "size": session.size,
            "komi": session.komi,
            "seat": 1,
            "yourColor": session.colorChar(guestColor),
            "opponentName": localName,
            "hostPlatform": "ios",
            "hints": hintsEnabled ? 1 : 0,
            "ruleset": session.game == LanProto.goGame ? "chinese-simple-ko" : "xiangqi",
            "serverTime": LanProto.nowMs()
        ]
        guard host?.send(LanProto.message(LanMsg.helloAck, room: roomCode, from: "host", payload: ack)) == true else {
            notice = "回送握手消息失败，请确认对手仍在同一网络"
            return
        }
        state = .lobby
        boardVersion += 1
    }

    private func sendHelloReject(_ code: String, _ message: String) {
        let payload: [String: Any] = ["code": code, "message": message, "ok": false]
        host?.send(LanProto.message(LanMsg.helloReject, room: roomCode, from: "host", payload: payload))
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.host?.closeGuest()
        }
    }

    private func onGuestMove(_ p: [String: Any]) {
        guard let session else { return }
        let guestColor = 3 - hostColor
        let r = session.applyAuthority(seat: guestColor, move: p,
                                       expectMoveNo: LanProto.int(p, "moveNo", 0),
                                       hashBefore: LanProto.string(p, "hashBefore"))
        guard r.ok else {
            var rej: [String: Any] = [
                "moveNo": LanProto.int(p, "moveNo", 0),
                "code": r.code,
                "message": r.message,
                "authoritativeMoveNo": session.moveNo,
                "hash": session.hash()
            ]
            if r.code == "E_HASH_MISMATCH" { rej["snapshot"] = session.snapshot() }
            host?.send(LanProto.message(LanMsg.moveReject, room: roomCode, from: "host", payload: rej))
            return
        }
        if let clock, clock.active {
            clock.onMove(guestColor - 1)
            if clock.timedOutColor >= 0 {
                hostTimeout(clock.timedOutColor)
                return
            }
        }
        sendAck(r)
        boardVersion += 1
        afterMove()
    }

    private func applyAck(_ p: [String: Any]) {
        guard let session else { return }
        let ok = session.applyAck(p, ackMoveNo: LanProto.int(p, "moveNo", 0),
                                  expectedHash: LanProto.string(p, "hash"))
        if let ck = p["clock"] as? [String: Any] {
            guestClock = ck
            guestClockAt = LanProto.uptimeMs()
        }
        if !ok {
            notice = "状态不同步，正在向房主校准…"
            sendToHost(LanProto.message(LanMsg.syncRequest, room: roomCode, from: "guest"))
        } else {
            playMoveSound()
        }
        boardVersion += 1
        clockTick += 1
    }

    /// 联机落子音效：与本地对局保持一致（落子/吃子共用落子音，将军用将军音）。
    /// 之前联机路径完全没有调用 SoundPlayer，所以双方都听不到声音。
    private func playMoveSound() {
        guard state == .playing else { return }
        if gameId == LanProto.goGame {
            SoundPlayer.shared.playStone()
            return
        }
        if let game = session?.xiangqi, game.inCheck(game.turn) {
            SoundPlayer.shared.playCheck()
        } else {
            SoundPlayer.shared.playMove()
        }
    }

    /// 终局音效：象棋沿用提示音；围棋按胜负方分别播放喝彩/收束音。
    private func playGameOverSound() {
        // 围棋按座位区分胜负：赢家喝彩音，输家收束音；不再复用象棋将军音。
        if gameId == LanProto.goGame {
            let won: Bool?
            if resultCode.hasPrefix("B+") { won = myColor == 1 }
            else if resultCode.hasPrefix("W+") { won = myColor == 2 }
            else { won = nil }
            switch won {
            case .some(true): SoundPlayer.shared.playWin()
            case .some(false): SoundPlayer.shared.playLose()
            case .none: SoundPlayer.shared.playLose()
            }
            return
        }
        SoundPlayer.shared.playCheck()
    }

    private func replyPong(_ ping: [String: Any]) {
        let payload: [String: Any] = [
            "t0": LanProto.int64(ping, "t0", 0),
            "serverTime": LanProto.nowMs()
        ]
        send(LanProto.message(LanMsg.pong, room: roomCode,
                              from: isHost ? "host" : "guest", payload: payload))
    }

    // MARK: - 发送

    private func send(_ msg: [String: Any]) {
        if isHost {
            host?.send(msg)
        } else {
            sendToHost(msg)
        }
    }

    @discardableResult
    private func sendToHost(_ msg: [String: Any]) -> Bool {
        guard let client else { return false }
        return client.send(msg)
    }

    // MARK: - 前后台

    /// 进入后台：系统即将挂起进程，先收回不可信的重连/宽限计时。
    /// 对局与棋盘全部保留，只暂停计时，不结束对局、不退出页面。
    func appMovedToBackground() {
        appInBackground = true
        guard state == .playing, linkDown else { return }
        if isHost {
            cancelGrace()
        } else {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    /// 回到前台：后台时长不计入重连宽限，重新开始一轮完整的恢复窗口。
    func appMovedToForeground() {
        appInBackground = false
        guard state == .playing else { return }
        if linkDown {
            if isHost {
                notice = "连接中断，计时已暂停，等待重连（\(LanProto.reconnectGraceMs / 1000) 秒）"
                scheduleGrace()
            } else {
                startReconnect()
            }
            return
        }
        // 挂起期间收不到心跳，回来后先给链路一个确认窗口，避免一回来就误判断线。
        lastRecvAt = LanProto.uptimeMs()
        lastPingAt = 0
        sendLinkPing()
    }

    // MARK: - 断线重连

    private func onHostLinkLost(_ reason: String) {
        guard state == .playing, !linkDown else { return }
        linkDown = true
        lastPingAt = 0
        if let clock {
            clock.pauseAt(lastRecvAt > 0 ? lastRecvAt : LanProto.uptimeMs())
            sendClock()
        }
        // 半开连接仍占着客机槽位，主动关闭，重连的新连接才进得来。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.state == .playing, self.linkDown else { return }
            self.host?.closeGuest()
        }
        notice = "\(reason)，计时已暂停，等待重连（\(LanProto.reconnectGraceMs / 1000) 秒）"
        clockTick += 1
        scheduleGrace()
    }

    /// 重新开始一轮完整的重连宽限（断线时、回到前台时各调用一次）。
    private func scheduleGrace() {
        cancelGrace()
        guard state == .playing, linkDown else { return }
        let task = DispatchWorkItem { [weak self] in
            // 后台恢复瞬间计时器可能先于 scenePhase 回调触发：此时先不判负，
            // 回到前台后 appMovedToForeground 会重新调度一轮完整宽限。
            guard let self, self.state == .playing, self.linkDown,
                  !self.appInBackground, let session = self.session else { return }
            self.hostFinishPayload(session.resultByDisconnect(3 - self.hostColor))
        }
        graceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(LanProto.reconnectGraceMs) / 1000, execute: task)
    }

    private func cancelGrace() {
        graceTask?.cancel()
        graceTask = nil
    }

    private func onClientLinkLost(_ reason: String) {
        guard state == .playing, !linkDown else { return }
        linkDown = true
        clockFrozen = true
        lastPingAt = 0
        notice = "连接中断，正在重连…（计时已暂停）"
        clockTick += 1
        startReconnect()
    }

    private func startReconnect() {
        guard !appInBackground else { return }
        linkEpoch += 1
        let epoch = linkEpoch
        let ip = lastHostIp
        let port = lastHostPort
        guard !ip.isEmpty, port > 0 else {
            failReconnect("没有可用的房主地址")
            return
        }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Double(LanProto.reconnectGraceMs) / 1000)
            while !Task.isCancelled, !self.appInBackground, self.linkEpoch == epoch,
                  self.state == .playing, self.linkDown, Date() < deadline {
                self.resetJoinWait()
                self.attemptSeq += 1
                let seq = self.attemptSeq
                let newClient = LanClient()
                self.client = newClient
                newClient.onMessage = { [weak self, weak newClient] msg in
                    Task { @MainActor in
                        guard let self, let newClient, self.attemptSeq == seq, self.client === newClient else { return }
                        self.onGuestMessage(msg)
                    }
                }
                newClient.onClosed = { [weak self, weak newClient] reason in
                    Task { @MainActor in
                        guard let self, let newClient, self.attemptSeq == seq, self.client === newClient else { return }
                        self.onClientClosed(reason)
                    }
                }
                newClient.connect(host: ip, port: port)

                var payload: [String: Any] = [
                    "protocolVersion": LanProto.version,
                    "roomCode": self.roomCode,
                    "deviceName": self.localName,
                    "platform": "ios",
                    "appVersion": self.appVersion,
                    "clientId": self.clientId,
                    "game": self.gameId,
                    "resume": true,
                    "gameId": self.session?.matchId ?? "",
                    "moveNo": self.session?.moveNo ?? 0
                ]
                payload["resume"] = true
                if !newClient.send(LanProto.message(LanMsg.hello, room: self.roomCode,
                                                    from: "guest", payload: payload)) {
                    if self.client === newClient { self.client = nil }
                    newClient.close()
                    try? await Task.sleep(nanoseconds: UInt64(LanProto.guestReconnectMs) * 1_000_000)
                    continue
                }
                _ = await self.waitHello(timeout: 6)
                if !self.linkDown {
                    self.reconnectTask = nil
                    return
                }
                if self.joinRejected && self.joinRejectCode == "E_NO_GAME" {
                    self.failReconnect("房主已结束这局对局")
                    return
                }
                self.attemptSeq += 1
                if self.client === newClient { self.client = nil }
                newClient.close()
                try? await Task.sleep(nanoseconds: UInt64(LanProto.guestReconnectMs) * 1_000_000)
            }
            if self.linkEpoch == epoch, self.state == .playing, self.linkDown,
               !Task.isCancelled, !self.appInBackground {
                self.failReconnect("重连宽限期已过")
            }
        }
    }

    private func failReconnect(_ reason: String) {
        guard state == .playing, linkDown, !appInBackground else { return }
        state = .finished
        stopLinkWatch()
        resultCode = ""
        resultReason = "disconnect"
        resultDetail = "与房主的连接未能恢复（\(reason)），对局结束"
        notice = resultDetail
        boardVersion += 1
    }

    // MARK: - 链路守护

    private func startLinkWatch() {
        linkTimer?.invalidate()
        linkTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.linkWatchTick() }
        }
    }

    private func stopLinkWatch() {
        linkTimer?.invalidate()
        linkTimer = nil
    }

    private func linkWatchTick() {
        guard state == .playing else {
            stopLinkWatch()
            return
        }
        guard !appInBackground else { return }
        let now = LanProto.uptimeMs()
        if isHost {
            guard !linkDown else { return }
            if now - lastPingAt >= LanProto.hostPingMs {
                lastPingAt = now
                sendLinkPing()
            }
            if lastRecvAt > 0, now - lastRecvAt > LanProto.hostIdleMs {
                onHostLinkLost("对手长时间无响应")
            }
        } else if !linkDown, lastRecvAt > 0, now - lastRecvAt > LanProto.guestIdleMs {
            onClientLinkLost("与房主连接超时")
        }
    }

    private func sendLinkPing() {
        let payload: [String: Any] = ["t0": LanProto.nowMs()]
        send(LanProto.message(LanMsg.ping, room: roomCode,
                              from: isHost ? "host" : "guest", payload: payload))
    }

    // MARK: - 时钟

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard state == .playing else { return }
        if isHost, let clock, clock.active {
            clock.tick()
            if clock.timedOutColor >= 0 {
                hostTimeout(clock.timedOutColor)
                return
            }
            let now = LanProto.uptimeMs()
            if now - lastClockPush >= 1000 {
                lastClockPush = now
                sendClock()
            }
        }
        clockTick += 1
    }

    private func sendClock() {
        guard let host, let clock, clock.active, let session else { return }
        host.send(LanProto.message(LanMsg.clock, room: roomCode,
                                   from: "host", payload: clock.snapshot(moveNo: session.moveNo)))
    }

    /// 双方剩余时间标签。seat 为 1/2。
    func clockLabel(seat: Int) -> String {
        let idx = seat == 1 ? 0 : 1
        let head = colorName(seat)
        if mainSec <= 0 { return "\(head) —" }
        if isHost, let clock {
            let ms = clock.remain(idx)
            if clock.inByoYomi(idx) {
                return "\(head) 读秒 \(max(0, ms / 1000))s ×\(max(0, clock.periodsRemaining(idx)))"
            }
            return "\(head) \(Self.formatClock(ms))"
        }
        if let ck = guestClock {
            let byoYomi = LanProto.bool(ck, idx == 0 ? "blackByoYomi" : "whiteByoYomi")
            var ms = LanProto.int64(ck, idx == 0 ? "blackRemainMs" : "whiteRemainMs")
            let running = LanProto.bool(ck, "running")
            let paused = LanProto.bool(ck, "paused")
            let turn = LanProto.string(ck, "turn")
            // 时钟用抽象色位：下标 0 对应 "B"（象棋即红方），与 Android `LanClock` 一致
            let seatTurn = turn == (idx == 0 ? "B" : "W")
            if running, seatTurn, !paused, !linkDown, !clockFrozen {
                ms -= LanProto.uptimeMs() - guestClockAt
            }
            ms = max(0, ms)
            if byoYomi {
                let left = LanProto.int(ck, idx == 0 ? "blackPeriods" : "whitePeriods")
                return "\(head) 读秒 \(ms / 1000)s ×\(left)"
            }
            return "\(head) \(Self.formatClock(ms))"
        }
        return "\(head) —"
    }

    private static func formatClock(_ ms: Int64) -> String {
        let seconds = max(0, ms) / 1000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - 停止

    func stop() {
        stopTicker()
        stopLinkWatch()
        cancelGrace()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        linkEpoch += 1
        linkDown = false
        appInBackground = false
        attemptSeq += 1
        joinCloseReason = "已停止"
        scorePending = false
        pendingScore = nil

        host?.stop()
        client?.close()
        discovery?.stop()
        queryResponder?.stop()

        host = nil
        client = nil
        discovery = nil
        queryResponder = nil
        session = nil
        guestPresent = false
        clock = nil
        guestClock = nil
        clockFrozen = false
        pendingMove = false
        pendingUndoFrom = nil
        incomingUndoFrom = nil
        outgoingUndo = false
        role = .none
        state = .idle
        roomCode = ""
        gameId = ""
        opponentName = "对手"
        resultCode = ""
        resultDetail = ""
        resultReason = ""
        lastError = ""
        notice = ""
        hostAddress = ""
        port = 0
        rooms = []
        lastHostIp = ""
        lastHostPort = 0
        lastRecvAt = 0
        lastPingAt = 0
        boardVersion += 1
        clockTick += 1
    }

    // MARK: - 工具

    /// 手动加入的候选地址。
    /// - 用户写了端口：先试该地址，再补一条发现列表里同 IP / 同房号的真实端口；
    /// - 用户只写 IP：优先用发现列表里该 IP 的真实端口，然后按 41234–41244 逐个尝试。
    /// 这样即使房主不在默认端口上，也不需要用户手填端口。
    func manualCandidates(_ text: String, code: String) -> [String] {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return [] }
        let normalizedCode = LanProto.normalizeRoomCode(code)
        let matched = rooms.first { room in
            (!normalizedCode.isEmpty && room.code.caseInsensitiveCompare(normalizedCode) == .orderedSame)
                || room.host == Self.hostOnly(value)
        }
        if let explicit = Self.explicitPort(value), let (ip, _) = Self.splitHostPort(value) {
            var list = ["\(ip):\(explicit)"]
            if let matched, matched.port != explicit {
                list.append("\(matched.host):\(matched.port)")
            }
            return list
        }
        let ip = Self.hostOnly(value)
        guard !ip.isEmpty else { return [] }
        var list: [String] = []
        if let matched { list.append("\(matched.host):\(matched.port)") }
        for port in LanProto.portCandidates where !list.contains("\(ip):\(port)") {
            list.append("\(ip):\(port)")
        }
        return list
    }

    /// 文本里显式写出的端口；没写端口（含裸 IPv6）返回 nil。
    static func explicitPort(_ text: String) -> UInt16? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return nil }
            let rest = String(value[value.index(after: end)...])
            guard rest.hasPrefix(":") else { return nil }
            return UInt16(rest.dropFirst())
        }
        guard value.filter({ $0 == ":" }).count == 1 else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return UInt16(String(parts[1]).trimmingCharacters(in: .whitespaces))
    }

    /// 去掉端口后的主机部分；裸 IPv6 原样返回。
    static func hostOnly(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") {
            return String(value[value.index(after: value.startIndex)..<end])
        }
        if value.filter({ $0 == ":" }).count == 1 {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2 { return String(parts[0]).trimmingCharacters(in: .whitespaces) }
        }
        return value
    }

    /// 解析 host:port / [v6]:port / 裸 IPv6（默认端口）。
    static func splitHostPort(_ text: String) -> (String, UInt16)? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<end])
            let rest = String(value[value.index(after: end)...])
            let portText = rest.hasPrefix(":") ? String(rest.dropFirst()) : String(LanProto.defaultPort)
            guard let port = UInt16(portText) else { return nil }
            return (host, port)
        }
        let colons = value.filter { $0 == ":" }.count
        if colons == 0 { return (value, LanProto.defaultPort) }
        if colons > 1 { return (value, LanProto.defaultPort) }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let host = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let portText = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = UInt16(portText), port > 0 else { return nil }
        return (host, port)
    }

    private static func safe(_ text: String?, _ def: String) -> String {
        let value = (text ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? def : value
    }
}
