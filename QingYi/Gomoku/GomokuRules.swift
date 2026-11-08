import Foundation
import CryptoKit

/// 移植自 Android `com.sijia.go.net.GomokuRules`
/// 源文件：app/src/main/java/com/sijia/go/net/GomokuRules.java（只读参考，未做任何修改）
///
/// 方法一一对应：
///   game / isRenju() / setRenju / reset
///   turn / moveCount / isOver / boardSize
///   hash(moveNo:)           ← hash（SHA-256，字符串拼法与 Java 逐字节一致）
///   snapshot / restore      ← snapshot / restore
///   apply(seat:move:)       ← apply（E_OUT_OF_TURN / E_OCCUPIED / E_ILLEGAL 及文案一致）
///   applyAck / undo / movePayload / lastMove
///   result / resultByResign / resultByTimeout / resultByDisconnect / scoreResult
///   colorChar / seatFromChar / colorName / supportsPass / supportsScore / coordinate
///
/// 本文件只做联机裁决，不依赖 UIKit / SwiftUI。仅额外 import CryptoKit 计算 SHA-256，
/// 与 Android 的 MessageDigest("SHA-256") 等价。
/// 房主侧用 apply(seat:move:) 做权威裁决；客机侧只用 applyAck / restore。
final class GomokuRules {
    static let gameID = "gomoku"
    static let gameLabel = "五子棋"

    /// 落子裁决结果，字段与 Android `GameAdapter.ApplyResult` 对应。
    struct ApplyResult {
        var ok = false
        var code = ""
        var message = ""
        var x = -1
        var y = -1
        var nextTurn = 1
    }

    /// 供 UI 显示的最后一手。
    struct MoveInfo {
        var seat = 0
        var fx = -1
        var fy = -1
        var text = ""
    }

    /// 棋规结果，对应 Java 的 result JSON（result / detail / reason）。
    struct GameResult {
        var result = ""
        var detail = ""
        var reason = ""
    }

    private(set) var game: GomokuGame
    /// 黑棋禁手（长连 / 四四 / 三三），由房主开局设置并在快照里同步。
    private(set) var renju = false

    init(size: Int = GomokuGame.boardSize) {
        game = GomokuGame(size: size)
    }

    func isRenju() -> Bool { renju }

    /// 必须在开局前调用；对局中切换会导致两端规则不一致。
    func setRenju(_ on: Bool) {
        renju = on
        game.isRenju = on
    }

    func id() -> String { GomokuRules.gameID }

    func label() -> String { GomokuRules.gameLabel }

    func boardSize() -> Int { game.size }

    func reset() {
        game = GomokuGame(size: GomokuGame.boardSize)
        game.isRenju = renju
    }

    func turn() -> Int { game.turn }

    func moveCount() -> Int { game.moveCount }

    func isOver() -> Bool { game.isOver }

    // MARK: - 哈希

    func hash(moveNo: Int) -> String {
        var s = "gomoku|1|SZ=\(game.size)|R=\(renju ? 1 : 0)|M=\(moveNo)"
        s += "|T=\(game.turn == GomokuGame.black ? "B" : "W")|W=\(game.winner)|"
        for y in 0..<game.size {
            if y > 0 { s.append("/") }
            for x in 0..<game.size {
                s.append(String(game.get(x, y)))
            }
        }
        return GomokuRules.sha256Hex(s)
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Foundation.Data(text.utf8))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }

    // MARK: - 快照

    func snapshot() -> [String: Any] {
        var o: [String: Any] = [:]
        o["gameId"] = id()
        o["size"] = game.size
        o["renju"] = renju
        o["toMove"] = colorChar(game.turn)
        o["winner"] = game.winner
        if let wl = game.winLine {
            o["winLine"] = [wl.x1, wl.y1, wl.x2, wl.y2]
        }
        o["moves"] = game.history.map { m -> [Any] in
            [colorChar(m.color), m.x, m.y]
        }
        return o
    }

    func restore(_ p: [String: Any]?) -> Bool {
        guard let p = p else { return false }
        let size = p["size"] as? Int ?? 19
        renju = p["renju"] as? Bool ?? false
        game = GomokuGame(size: size)
        game.isRenju = renju
        if let arr = p["moves"] as? [[Any]] {
            for one in arr {
                guard one.count >= 3,
                      let x = one[1] as? Int,
                      let y = one[2] as? Int else { return false }
                if !game.play(x, y) { return false }
            }
        }
        return true
    }

    // MARK: - 落子

    /// 房主权威裁决。move 里的字段与线协议一致（顶层 x / y）。
    func apply(seat: Int, move: [String: Any]) -> ApplyResult {
        var r = ApplyResult()
        r.nextTurn = game.turn
        if seat != game.turn {
            r.code = "E_OUT_OF_TURN"
            r.message = "还没轮到这一方"
            return r
        }
        let x = move["x"] as? Int ?? -1
        let y = move["y"] as? Int ?? -1
        if x < 0 || y < 0 || x >= game.size || y >= game.size {
            r.code = "E_OCCUPIED"
            r.message = "落点超出棋盘"
            return r
        }
        if game.get(x, y) != GomokuGame.empty {
            r.code = "E_OCCUPIED"
            r.message = "这里已经有子了"
            return r
        }
        let res = game.tryPlay(x, y)
        if res == GomokuGame.playForbidden {
            r.code = "E_ILLEGAL"
            r.message = game.forbiddenText(x, y)
            return r
        }
        if res != GomokuGame.playOK {
            r.code = "E_ILLEGAL"
            r.message = "这一手不能下"
            return r
        }
        r.ok = true
        r.x = x
        r.y = y
        r.nextTurn = game.turn
        return r
    }

    /// 客机镜像房主的落子（与 Java 一样只做 play，不校验 moveNo / expectedHash）。
    func applyAck(_ ack: [String: Any], moveNo: Int, expectedHash: String) -> Bool {
        game.play(ack["x"] as? Int ?? -1, ack["y"] as? Int ?? -1)
    }

    func undo(_ count: Int) -> Int {
        var done = 0
        var i = 0
        while i < count && game.canUndo {
            game.undo()
            done += 1
            i += 1
        }
        return done
    }

    /// 客机构造 move 消息：补全棋种字段与 hashBefore。
    func movePayload(seat: Int, move: [String: Any], hashBefore: String) -> [String: Any] {
        var p: [String: Any] = [
            "pass": false,
            "x": move["x"] as? Int ?? -1,
            "y": move["y"] as? Int ?? -1
        ]
        if !hashBefore.isEmpty { p["hashBefore"] = hashBefore }
        return p
    }

    func lastMove() -> MoveInfo? {
        guard let m = game.history.last else { return nil }
        return MoveInfo(seat: m.color, fx: m.x, fy: m.y, text: coordinate(m.x, m.y))
    }

    // MARK: - 结果

    func result() -> GameResult? {
        guard game.isOver else { return nil }
        let code = game.winner == GomokuGame.black ? "B+5" : "W+5"
        return GomokuRules.makeResult(code: code,
                                      detail: colorName(game.winner) + "方五连获胜",
                                      reason: "rule")
    }

    func resultByResign(_ resignSeat: Int) -> GameResult {
        let winner = 3 - resignSeat
        return GomokuRules.makeResult(code: colorChar(winner) + "+R",
                                      detail: colorName(resignSeat) + "方认输，"
                                          + colorName(winner) + "方中盘胜",
                                      reason: "resign")
    }

    func resultByTimeout(_ timeoutSeat: Int) -> GameResult {
        let winner = 3 - timeoutSeat
        return GomokuRules.makeResult(code: colorChar(winner) + "+T",
                                      detail: colorName(timeoutSeat) + "方超时，"
                                          + colorName(winner) + "方胜",
                                      reason: "timeout")
    }

    func resultByDisconnect(_ lostSeat: Int) -> GameResult {
        let winner = 3 - lostSeat
        return GomokuRules.makeResult(code: colorChar(winner) + "+R",
                                      detail: colorName(lostSeat) + "方断线，"
                                          + colorName(winner) + "方中盘胜",
                                      reason: "disconnect")
    }

    func scoreResult() -> [String: Any]? { nil }

    private static func makeResult(code: String, detail: String, reason: String) -> GameResult {
        GameResult(result: code, detail: detail, reason: reason)
    }

    // MARK: - 颜色 / 坐标

    func colorChar(_ seat: Int) -> String {
        seat == GomokuGame.black ? "B" : "W"
    }

    func seatFromChar(_ s: String) -> Int {
        s.uppercased() == "B" ? GomokuGame.black : GomokuGame.white
    }

    func colorName(_ seat: Int) -> String {
        seat == GomokuGame.black ? "黑" : "白"
    }

    func supportsPass() -> Bool { false }

    func supportsScore() -> Bool { false }

    /// 与 Java 相同：列用大写字母，行号从棋盘底部往上数。
    func coordinate(_ x: Int, _ y: Int) -> String {
        String(Character(UnicodeScalar(UInt8(65 + x)))) + String(game.size - y)
    }
}

#if DEBUG

/// 纯逻辑自检。Windows 下无法运行 Swift，此代码只保证语法正确；
/// 在 Xcode 里调用 `GomokuSelfCheck.run()`，返回空数组即全部通过。
enum GomokuSelfCheck {

    /// 返回失败项描述；空数组表示全部通过。
    @discardableResult
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ message: String) {
            if !ok { failures.append(message) }
        }

        // 1. 19 路边界
        let edge = GomokuGame()
        expect(edge.size == 19, "默认棋盘应为 19 路")
        expect(edge.board.count == 361, "19 路棋盘应有 361 个点")
        expect(edge.get(-1, 0) == GomokuGame.empty, "越界 x<0 应返回空")
        expect(edge.get(0, -1) == GomokuGame.empty, "越界 y<0 应返回空")
        expect(edge.get(19, 0) == GomokuGame.empty, "越界 x=19 应返回空")
        expect(edge.get(0, 19) == GomokuGame.empty, "越界 y=19 应返回空")
        expect(edge.tryPlay(19, 0) == GomokuGame.playOccupied, "越界落子应返回 occupied")
        expect(GomokuGame(size: 3).size == 5, "size 下限应夹到 5")
        expect(GomokuGame(size: 30).size == 25, "size 上限应夹到 25")

        // 2. 五连判胜（横 / 竖 / 两斜）
        func expectWin(_ black: [(Int, Int)], _ white: [(Int, Int)],
                       _ last: (Int, Int), _ tag: String) {
            let g = GomokuGame()
            for i in 0..<black.count {
                expect(g.play(black[i].0, black[i].1), "\(tag)：黑第 \(i + 1) 手应合法")
                if i < white.count {
                    expect(g.play(white[i].0, white[i].1), "\(tag)：白第 \(i + 1) 手应合法")
                }
            }
            expect(g.play(last.0, last.1), "\(tag)：制胜手应合法")
            expect(g.winner == GomokuGame.black, "\(tag)：应判黑胜")
            expect(g.winLine != nil, "\(tag)：应记录五连首尾")
        }
        expectWin([(3, 9), (4, 9), (5, 9), (6, 9)],
                  [(3, 10), (4, 10), (5, 10), (6, 10)], (7, 9), "横向五连")
        expectWin([(9, 3), (9, 4), (9, 5), (9, 6)],
                  [(10, 3), (10, 4), (10, 5), (10, 6)], (9, 7), "纵向五连")
        expectWin([(3, 3), (4, 4), (5, 5), (6, 6)],
                  [(3, 10), (4, 10), (5, 10), (6, 10)], (7, 7), "斜向↘五连")
        expectWin([(3, 11), (4, 10), (5, 9), (6, 8)],
                  [(10, 3), (10, 4), (10, 5), (10, 6)], (7, 7), "斜向↗五连")

        // 3. 长连禁手（黑棋六连）
        let over = GomokuGame()
        over.isRenju = true
        let ob = [(4, 9), (5, 9), (6, 9), (8, 9), (9, 9)]
        let ow = [(0, 0), (3, 0), (6, 0), (9, 0), (12, 0)]
        for i in 0..<ob.count {
            expect(over.play(ob[i].0, ob[i].1), "长连：黑前置手 \(i + 1) 应合法")
            expect(over.play(ow[i].0, ow[i].1), "长连：白第 \(i + 1) 手应合法")
        }
        let overBefore = over.moveCount
        expect(over.tryPlay(7, 9) == GomokuGame.playForbidden, "长连应判 playForbidden")
        expect(over.forbiddenText(7, 9).contains("长连"), "长连应返回对应文案")
        expect(over.moveCount == overBefore, "长连禁手不得改变手数")
        expect(over.get(7, 9) == GomokuGame.empty, "长连禁手不得落子")

        // 4. 三三禁手
        let d3 = GomokuGame()
        d3.isRenju = true
        let d3b = [(7, 9), (8, 9), (9, 7), (9, 8)]
        let d3w = [(1, 1), (4, 1), (7, 1), (10, 1)]
        for i in 0..<d3b.count {
            expect(d3.play(d3b[i].0, d3b[i].1), "三三：黑前置手 \(i + 1) 应合法")
            expect(d3.play(d3w[i].0, d3w[i].1), "三三：白第 \(i + 1) 手应合法")
        }
        let d3Before = d3.moveCount
        expect(d3.tryPlay(9, 9) == GomokuGame.playForbidden, "三三应判 playForbidden")
        expect(d3.forbiddenText(9, 9).contains("三三"), "三三应返回对应文案")
        expect(d3.moveCount == d3Before, "三三禁手不得改变手数")

        // 5. 四四禁手
        let d4 = GomokuGame()
        d4.isRenju = true
        let d4b = [(5, 9), (6, 9), (7, 9), (9, 5), (9, 6), (9, 7)]
        let d4w = [(1, 1), (4, 1), (7, 1), (10, 1), (13, 1), (16, 1)]
        for i in 0..<d4b.count {
            expect(d4.play(d4b[i].0, d4b[i].1), "四四：黑前置手 \(i + 1) 应合法")
            expect(d4.play(d4w[i].0, d4w[i].1), "四四：白第 \(i + 1) 手应合法")
        }
        let d4Before = d4.moveCount
        expect(d4.tryPlay(9, 9) == GomokuGame.playForbidden, "四四应判 playForbidden")
        expect(d4.forbiddenText(9, 9).contains("四四"), "四四应返回对应文案")
        expect(d4.moveCount == d4Before, "四四禁手不得改变手数")

        // 6. 悔棋回滚
        let u = GomokuGame()
        expect(u.play(9, 9) && u.play(10, 10), "悔棋：前置两手应合法")
        expect(u.turn == GomokuGame.black, "悔棋前应轮到黑")
        expect(u.undo(), "悔棋：应能悔一手")
        expect(u.get(10, 10) == GomokuGame.empty, "悔棋后白子应清除")
        expect(u.turn == GomokuGame.white, "悔棋后应轮到白")
        expect(u.lastX == 9 && u.lastY == 9, "悔棋后最后一手应回到黑 (9,9)")
        expect(u.undo(), "悔棋：应能悔第二手")
        expect(u.get(9, 9) == GomokuGame.empty, "悔棋后黑子应清除")
        expect(u.turn == GomokuGame.black, "悔棋后应轮到黑")
        expect(u.lastX == -1 && u.lastY == -1, "空盘最后一手应为 -1")
        expect(!u.canUndo, "空盘不应再能悔棋")

        let won = GomokuGame()
        for i in 0..<4 {
            _ = won.play(3 + i, 9)
            _ = won.play(3 + i, 10)
        }
        _ = won.play(7, 9)
        expect(won.isOver, "悔棋用例：应先判胜")
        expect(won.undo(), "悔棋：胜局应能悔最后一手")
        expect(!won.isOver && won.winLine == nil, "悔棋后胜负与五连应清空")
        expect(won.turn == GomokuGame.black, "悔棋后应轮到黑")

        // 7. SGF 往返一致
        let rec = GomokuGame()
        rec.isRenju = true
        _ = rec.play(9, 9)
        _ = rec.play(10, 10)
        _ = rec.play(9, 10)
        _ = rec.play(10, 9)
        _ = rec.play(8, 8)
        let text = GomokuRecord.toSgf(rec, blackName: "黑方", whiteName: "白方", result: "B+5")
        let parsed = GomokuRecord.parse(text)
        expect(parsed.size == 19, "SGF：SZ 应往返一致")
        expect(parsed.renju, "SGF：RU 应往返一致")
        expect(parsed.result == "B+5", "SGF：RE 应往返一致")
        expect(parsed.moves.count == rec.history.count, "SGF：手数应往返一致")
        if parsed.moves.count == rec.history.count {
            for i in 0..<parsed.moves.count {
                expect(parsed.moves[i] == rec.history[i], "SGF：第 \(i + 1) 手应往返一致")
            }
        }
        expect(text.contains("GM[4]"), "SGF：应含 GM[4]")
        expect(text.contains("SZ[19]"), "SGF：应含 SZ[19]")
        expect(text.contains("RU[renju]"), "SGF：应含 RU[renju]")
        expect(text.contains("RE[B+5]"), "SGF：应含 RE[B+5]")
        expect(text.contains(";B[jj]"), "SGF：黑 (9,9) 应编码为 jj")
        expect(text.contains(";W[kk]"), "SGF：白 (10,10) 应编码为 kk")
        expect(text.hasSuffix(")\n"), "SGF：应以右括号加换行结尾")

        return failures
    }
}

#endif
