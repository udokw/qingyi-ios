//
//  BanqiGame.swift
//  清弈
//
//  移植自 Android：app/src/main/java/com/sijia/go/banqi/BanqiGame.java
//  暗棋（翻翻棋）规则引擎，纯逻辑层，不依赖 UI 框架。
//
//  棋盘 4 行 × 8 列，坐标 (x, y)：x 从左到右 0..7，y 从上到下 0..3。
//  内部存储与 Java 一致，使用 board[y][x]（行优先），不要转置。
//
//  规则要点（与 Java 逐条一致）：
//  - 每回合二选一：翻任意暗子，或走一枚己方明子一格/吃子；
//  - 首翻定色，之后翻出的子按棋子颜色归属；
//  - 军衔 將 > 士 > 象 > 車 > 馬 > 炮 > 卒，同级可互吃；
//  - 卒可吃將，將不能吃卒；
//  - 炮只能走一格空格，吃子必须隔恰好一枚炮架跳吃，炮架可为明子或暗子；
//  - 无合法步判负；连续 30 步无吃子无翻子判和；同一局面三次判和。
//

import Foundation

/// 终局原因。
///
/// 与 Android 的差异：Java 侧 `BanqiRules.resultByTimeout` / `resultByDisconnect`
/// 都复用了 `BanqiGame.resign()`，导致 detail 文案变成「认输」。
/// Swift 侧把认输 / 超时 / 断线拆成三个独立 case，便于 UI 与联机结果正确显示。
enum BanqiEndReason: Equatable {
    case none
    case resign(seat: Int)
    case timeout(seat: Int)
    case disconnect(seat: Int)
    /// 无子可动判负，seat 为输家座位。
    case noLegalMove(seat: Int)
    /// 双方均无子可动，判和。
    case mutualNoMoveDraw
    case agreedDraw
    case repeatDraw
    case idleDraw

    /// 联机协议里的 reason 字段（resign / timeout / disconnect / rule / draw）。
    var protocolReason: String {
        switch self {
        case .none:
            return ""
        case .resign:
            return "resign"
        case .timeout:
            return "timeout"
        case .disconnect:
            return "disconnect"
        case .noLegalMove:
            return "rule"
        case .mutualNoMoveDraw, .agreedDraw, .repeatDraw, .idleDraw:
            return "draw"
        }
    }

    /// 认输 / 超时 / 断线 / 无子可动对应的座位号；其它情况为 0。
    var loserSeat: Int {
        switch self {
        case .resign(let seat), .timeout(let seat), .disconnect(let seat), .noLegalMove(let seat):
            return seat
        default:
            return 0
        }
    }
}

/// 暗棋棋局与规则。
final class BanqiGame {

    // MARK: - 常量（与 Java 完全一致）

    static let empty = 0
    /// 联机镜像时“有子但身份未知”的占位编码。
    static let hidden = -1

    static let red = 1
    static let black = 2

    /// 棋子类型。
    static let king = 0
    static let advisor = 1
    static let elephant = 2
    static let rook = 3
    static let horse = 4
    static let cannon = 5
    static let pawn = 6

    static let rows = 4
    static let cols = 8

    static let resultNone = 0
    static let resultDraw = 3

    static let seatFirst = 1
    static let seatSecond = 2

    /// 双方合计连续多少步无吃子无翻子判和。
    static let drawIdlePlies = 30
    /// 同一局面出现多少次判和。
    static let repeatDrawCount = 3

    private static let counts = [1, 2, 2, 2, 2, 2, 5]
    private static let ranks = [7, 6, 5, 4, 3, 2, 1]
    private static let names = ["將", "士", "象", "車", "馬", "炮", "卒"]
    /// 与现有象棋 FEN 风格一致：k/a/b/r/n/c/p，红大写、黑小写。
    private static let fenChars: [Character] = ["k", "a", "b", "r", "n", "c", "p"]
    private static let ortho: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    // MARK: - 一步棋

    /// 一步棋。翻子时 tx/ty 为 -1。
    struct Move: Equatable {
        let flip: Bool
        let x: Int
        let y: Int
        let tx: Int
        let ty: Int

        /// 执行后：翻出的子 / 移动的子。
        var piece: Int
        /// 执行后：被吃的子，0 表示无。
        var captured: Int
        /// 执行时轮到哪个座位。
        var seat: Int

        var prevTurn: Int
        var prevSeat1: Int
        var prevSeat2: Int
        var prevIdle: Int
        var prevBoard: Int

        /// 翻子。
        init(x: Int, y: Int) {
            self.flip = true
            self.x = x
            self.y = y
            self.tx = -1
            self.ty = -1
            self.piece = 0
            self.captured = 0
            self.seat = 0
            self.prevTurn = 0
            self.prevSeat1 = 0
            self.prevSeat2 = 0
            self.prevIdle = 0
            self.prevBoard = 0
        }

        /// 走子 / 吃子。
        init(fromX: Int, fromY: Int, toX: Int, toY: Int) {
            self.flip = false
            self.x = fromX
            self.y = fromY
            self.tx = toX
            self.ty = toY
            self.piece = 0
            self.captured = 0
            self.seat = 0
            self.prevTurn = 0
            self.prevSeat1 = 0
            self.prevSeat2 = 0
            self.prevIdle = 0
            self.prevBoard = 0
        }

        /// 协议/日志用的稳定键。
        var key: String {
            flip ? "f\(x),\(y)" : "m\(x),\(y)-\(tx),\(ty)"
        }

        /// 只比较着法本身（起止点 / 是否翻子），与 Java 的 `key()` 语义一致。
        static func == (lhs: Move, rhs: Move) -> Bool {
            lhs.flip == rhs.flip && lhs.x == rhs.x && lhs.y == rhs.y
                && lhs.tx == rhs.tx && lhs.ty == rhs.ty
        }
    }

    // MARK: - 状态

    private var board: [[Int]] = Array(
        repeating: Array(repeating: BanqiGame.empty, count: BanqiGame.cols),
        count: BanqiGame.rows
    )
    private var faceUp: [[Bool]] = Array(
        repeating: Array(repeating: false, count: BanqiGame.cols),
        count: BanqiGame.rows
    )
    /// 下标 1/2 为座位号，值为 red/black，0 表示首翻前未定。
    private var seatColor = [0, 0, 0]

    private var turn = BanqiGame.seatFirst
    private var idlePliesValue = 0
    private var pliesValue = 0
    private var resultValue = BanqiGame.resultNone
    private var endReasonValue = ""
    private var endReasonKindValue: BanqiEndReason = .none
    /// true 表示暗子携带真实身份（单机）；false 表示联机镜像，暗子为 hidden。
    private var fullSetKnown = true

    /// 最新的着法在最前，与 Java `ArrayDeque.push` 一致。
    private var history: [Move] = []
    private var positionKeys: [String] = []

    // MARK: - 初始化

    init() {
        reset()
    }

    init(seed: Int64) {
        reset(seed: seed)
    }

    private init(copying src: BanqiGame) {
        board = src.board
        faceUp = src.faceUp
        seatColor = src.seatColor
        turn = src.turn
        idlePliesValue = src.idlePliesValue
        pliesValue = src.pliesValue
        resultValue = src.resultValue
        endReasonValue = src.endReasonValue
        endReasonKindValue = src.endReasonKindValue
        fullSetKnown = src.fullSetKnown
        history = []
        positionKeys = src.positionKeys
    }

    /// 供 AI 推演使用：复制完整局面，历史不复制。
    func copyForSearch() -> BanqiGame {
        BanqiGame(copying: self)
    }

    /// 洗牌并铺满 32 格，全部背面朝上，座位颜色未定，先手先翻。
    func reset() {
        reset(seed: Int64.random(in: Int64.min...Int64.max))
    }

    func reset(seed: Int64) {
        var random = BanqiJavaRandom(seed: seed)
        var bag: [Int] = []
        bag.reserveCapacity(BanqiGame.rows * BanqiGame.cols)
        for color in BanqiGame.red...BanqiGame.black {
            for type in 0..<BanqiGame.counts.count {
                for _ in 0..<BanqiGame.counts[type] {
                    bag.append(BanqiGame.piece(color: color, type: type))
                }
            }
        }
        var i = bag.count - 1
        while i > 0 {
            let j = random.nextInt(i + 1)
            bag.swapAt(i, j)
            i -= 1
        }
        var index = 0
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                board[y][x] = bag[index]
                index += 1
                faceUp[y][x] = false
            }
        }
        seatColor[1] = 0
        seatColor[2] = 0
        turn = BanqiOptions.firstSeat == BanqiGame.seatSecond ? BanqiGame.seatSecond : BanqiGame.seatFirst
        idlePliesValue = 0
        pliesValue = 0
        resultValue = BanqiGame.resultNone
        endReasonValue = ""
        endReasonKindValue = .none
        fullSetKnown = true
        history.removeAll()
        positionKeys.removeAll()
        positionKeys.append(positionKey)
    }

    /// 测试/残局摆盘。encoded 中 0=空格，hidden=身份未知的暗子，其余为真实编码。
    /// 会自动按 seat1Color 推导 seat2Color。
    func setup(encoded: [[Int]]?, up: [[Bool]]?, seat1Color: Int, turnSeat: Int, idle: Int) {
        setup(encoded: encoded, up: up, seat1Color: seat1Color, turnSeat: turnSeat, idle: idle, known: true)
    }

    func setup(encoded: [[Int]]?, up: [[Bool]]?, seat1Color: Int, turnSeat: Int, idle: Int, known: Bool) {
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                var p = BanqiGame.empty
                if let encoded, y < encoded.count, x < encoded[y].count {
                    p = encoded[y][x]
                }
                board[y][x] = p
                var isUp = false
                if let up, y < up.count, x < up[y].count, up[y][x], p != BanqiGame.empty {
                    isUp = true
                }
                faceUp[y][x] = isUp
            }
        }
        fullSetKnown = known
        seatColor[1] = (seat1Color == BanqiGame.red || seat1Color == BanqiGame.black) ? seat1Color : 0
        seatColor[2] = seatColor[1] == 0 ? 0 : 3 - seatColor[1]
        turn = turnSeat == BanqiGame.seatSecond ? BanqiGame.seatSecond : BanqiGame.seatFirst
        idlePliesValue = max(0, idle)
        pliesValue = 0
        resultValue = BanqiGame.resultNone
        endReasonValue = ""
        endReasonKindValue = .none
        history.removeAll()
        positionKeys.removeAll()
        positionKeys.append(positionKey)
    }

    // MARK: - 编码与查询

    static func piece(color: Int, type: Int) -> Int {
        color == BanqiGame.red ? type + 1 : type + 9
    }

    static func colorOf(_ p: Int) -> Int {
        if p <= 0 { return 0 }
        return p <= 7 ? BanqiGame.red : BanqiGame.black
    }

    static func typeOf(_ p: Int) -> Int {
        if p <= 0 { return -1 }
        return p <= 7 ? p - 1 : p - 9
    }

    static func rankOf(_ type: Int) -> Int {
        (type >= 0 && type < BanqiGame.ranks.count) ? BanqiGame.ranks[type] : 0
    }

    static func pieceName(_ p: Int) -> String {
        let type = BanqiGame.typeOf(p)
        return type >= 0 ? BanqiGame.names[type] : "?"
    }

    static func colorName(_ color: Int) -> String {
        if color == BanqiGame.red { return "红" }
        if color == BanqiGame.black { return "黑" }
        return "未定"
    }

    static func coord(_ x: Int, _ y: Int) -> String {
        let letters = Array("abcdefgh")
        return String(letters[x]) + String(y + 1)
    }

    static func inBoard(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < BanqiGame.cols && y >= 0 && y < BanqiGame.rows
    }

    /// 该格是否有棋子（暗子身份未知也算有子）。
    func hasPieceAt(_ x: Int, _ y: Int) -> Bool {
        BanqiGame.inBoard(x, y) && board[y][x] != BanqiGame.empty
    }

    func isFaceUp(_ x: Int, _ y: Int) -> Bool {
        BanqiGame.inBoard(x, y) && faceUp[y][x]
    }

    func isHiddenAt(_ x: Int, _ y: Int) -> Bool {
        BanqiGame.inBoard(x, y) && board[y][x] != BanqiGame.empty && !faceUp[y][x]
    }

    func isEmptyAt(_ x: Int, _ y: Int) -> Bool {
        BanqiGame.inBoard(x, y) && board[y][x] == BanqiGame.empty
    }

    /// 返回编码；暗子可能返回 hidden（联机镜像）。UI 必须先判断 isFaceUp。
    func pieceCodeAt(_ x: Int, _ y: Int) -> Int {
        BanqiGame.inBoard(x, y) ? board[y][x] : BanqiGame.empty
    }

    /// 只读棋盘快照，索引方式为 [y][x]（4 行 × 8 列）。
    var boardCodes: [[Int]] {
        board
    }

    /// 只读明面快照，索引方式为 [y][x]（4 行 × 8 列）。
    var faceUpGrid: [[Bool]] {
        faceUp
    }

    var turnSeat: Int {
        turn
    }

    /// 当前行动方的颜色；首翻前为 0。
    var turnColor: Int {
        seatColor[turn]
    }

    func colorOfSeat(_ seat: Int) -> Int {
        (seat == BanqiGame.seatFirst || seat == BanqiGame.seatSecond) ? seatColor[seat] : 0
    }

    /// 颜色对应的座位；未定返回 0。
    func seatOfColor(_ color: Int) -> Int {
        if color == BanqiGame.red || color == BanqiGame.black {
            for seat in BanqiGame.seatFirst...BanqiGame.seatSecond where seatColor[seat] == color {
                return seat
            }
        }
        return 0
    }

    var idlePlies: Int {
        idlePliesValue
    }

    var plies: Int {
        pliesValue
    }

    var result: Int {
        resultValue
    }

    var endReason: String {
        endReasonValue
    }

    var endReasonKind: BanqiEndReason {
        endReasonKindValue
    }

    var isOver: Bool {
        resultValue != BanqiGame.resultNone
    }

    var isFullSetKnown: Bool {
        fullSetKnown
    }

    /// 最新的着法在最前，与 Java `historySnapshot()` 顺序一致。
    func historySnapshot() -> [Move] {
        history
    }

    var lastMove: Move? {
        history.first
    }

    func repeatCountAtCurrent() -> Int {
        let key = positionKey
        var count = 0
        for s in positionKeys where s == key {
            count += 1
        }
        return count
    }

    // MARK: - 规则判定

    /// 走步吃子：同级可互吃；將不能吃卒、卒能吃將、炮不能走步吃任何子。
    static func canCaptureByStep(_ attacker: Int, _ defender: Int) -> Bool {
        if attacker <= 0 || defender <= 0 {
            return false
        }
        let a = BanqiGame.typeOf(attacker)
        let d = BanqiGame.typeOf(defender)
        if a == BanqiGame.cannon && !BanqiOptions.cannonCanCaptureByStep {
            return false
        }
        if a == BanqiGame.king && d == BanqiGame.pawn {
            return false
        }
        if a == BanqiGame.pawn && d == BanqiGame.king {
            return true
        }
        return BanqiOptions.equalRankCanCapture
            ? BanqiGame.rankOf(a) >= BanqiGame.rankOf(d)
            : BanqiGame.rankOf(a) > BanqiGame.rankOf(d)
    }

    // MARK: - 合法着生成

    func legalActions() -> [Move] {
        var out: [Move] = []
        if resultValue != BanqiGame.resultNone {
            return out
        }
        addFlips(&out)
        let color = seatColor[turn]
        if color != 0 {
            addMovesForColor(&out, color: color)
        }
        return out
    }

    func legalFlips() -> [Move] {
        var out: [Move] = []
        if resultValue != BanqiGame.resultNone {
            return out
        }
        addFlips(&out)
        return out
    }

    /// 某格明子的所有走子/吃子（不含翻子）。
    func legalMovesFrom(_ x: Int, _ y: Int) -> [Move] {
        var out: [Move] = []
        if resultValue != BanqiGame.resultNone || !isFaceUp(x, y) {
            return out
        }
        let p = board[y][x]
        if BanqiGame.colorOf(p) != seatColor[turn] {
            return out
        }
        addMovesFrom(&out, x: x, y: y, p: p)
        return out
    }

    /// 指定颜色（不看轮次）的全部走子/吃子，供 AI 评估使用。
    func movesForColor(_ color: Int) -> [Move] {
        var out: [Move] = []
        if (color == BanqiGame.red || color == BanqiGame.black) && resultValue == BanqiGame.resultNone {
            addMovesForColor(&out, color: color)
        }
        return out
    }

    private func addFlips(_ out: inout [Move]) {
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                if board[y][x] != BanqiGame.empty && !faceUp[y][x] {
                    out.append(Move(x: x, y: y))
                }
            }
        }
    }

    private func addMovesForColor(_ out: inout [Move], color: Int) {
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                let p = board[y][x]
                if faceUp[y][x] && p != BanqiGame.empty && BanqiGame.colorOf(p) == color {
                    addMovesFrom(&out, x: x, y: y, p: p)
                }
            }
        }
    }

    private func addMovesFrom(_ out: inout [Move], x: Int, y: Int, p: Int) {
        let color = BanqiGame.colorOf(p)
        for d in BanqiGame.ortho {
            let nx = x + d.0
            let ny = y + d.1
            if !BanqiGame.inBoard(nx, ny) {
                continue
            }
            let q = board[ny][nx]
            if q == BanqiGame.empty {
                out.append(Move(fromX: x, fromY: y, toX: nx, toY: ny))
            } else if faceUp[ny][nx] && BanqiGame.colorOf(q) != color && BanqiGame.canCaptureByStep(p, q) {
                var m = Move(fromX: x, fromY: y, toX: nx, toY: ny)
                m.piece = p
                m.captured = q
                out.append(m)
            }
        }
        if BanqiGame.typeOf(p) == BanqiGame.cannon {
            addCannonJumps(&out, x: x, y: y, p: p)
        }
    }

    /// 炮隔一子跳吃：炮架可为明子/暗子、任意颜色；目标必须是对方明子；不可连跳。
    private func addCannonJumps(_ out: inout [Move], x: Int, y: Int, p: Int) {
        let color = BanqiGame.colorOf(p)
        for d in BanqiGame.ortho {
            var sx = x + d.0
            var sy = y + d.1
            while BanqiGame.inBoard(sx, sy) && board[sy][sx] == BanqiGame.empty {
                sx += d.0
                sy += d.1
            }
            if !BanqiGame.inBoard(sx, sy) {
                continue
            }
            if !faceUp[sy][sx] && !BanqiOptions.cannonScreenMayBeHidden {
                continue
            }
            var tx = sx + d.0
            var ty = sy + d.1
            while BanqiGame.inBoard(tx, ty) && board[ty][tx] == BanqiGame.empty {
                tx += d.0
                ty += d.1
            }
            if !BanqiGame.inBoard(tx, ty) || !faceUp[ty][tx] {
                continue
            }
            let q = board[ty][tx]
            if BanqiGame.colorOf(q) == color {
                continue
            }
            var m = Move(fromX: x, fromY: y, toX: tx, toY: ty)
            m.piece = p
            m.captured = q
            out.append(m)
        }
    }

    // MARK: - 执行与撤销

    /// 按坐标走子；成功返回 true。
    func play(fromX fx: Int, fromY fy: Int, toX tx: Int, toY ty: Int) -> Bool {
        if resultValue != BanqiGame.resultNone {
            return false
        }
        let legal = legalMovesFrom(fx, fy)
        for m in legal where m.tx == tx && m.ty == ty {
            commitMove(m)
            return true
        }
        return false
    }

    /// 单机/本地双人翻子：从引擎内部读取暗子身份。联机镜像请用 flipWith。
    func flip(x: Int, y: Int) -> Bool {
        if resultValue != BanqiGame.resultNone || !BanqiGame.inBoard(x, y) {
            return false
        }
        let p = board[y][x]
        if p == BanqiGame.empty || p == BanqiGame.hidden || faceUp[y][x] {
            return false
        }
        return flipWith(x: x, y: y, revealed: p)
    }

    /// 翻子并显式指定翻出的真实身份（联机客机按房主裁决调用）。
    func flipWith(x: Int, y: Int, revealed: Int) -> Bool {
        if resultValue != BanqiGame.resultNone || !BanqiGame.inBoard(x, y) || faceUp[y][x] {
            return false
        }
        if board[y][x] == BanqiGame.empty || revealed <= 0 || BanqiGame.typeOf(revealed) < 0 {
            return false
        }
        var m = Move(x: x, y: y)
        m.prevBoard = board[y][x]
        m.piece = revealed
        m.seat = turn
        m.prevTurn = turn
        m.prevSeat1 = seatColor[1]
        m.prevSeat2 = seatColor[2]
        m.prevIdle = idlePliesValue

        if seatColor[1] == 0 && seatColor[2] == 0 {
            let color = BanqiGame.colorOf(revealed)
            seatColor[turn] = color
            seatColor[3 - turn] = 3 - color
        }
        board[y][x] = revealed
        faceUp[y][x] = true
        finishAction(m, progress: true)
        return true
    }

    /// 执行一个由 legalActions() 产生的着法；翻子时按引擎内部身份翻开。
    func play(_ m: Move) -> Bool {
        if m.flip {
            if m.piece > 0 {
                return flipWith(x: m.x, y: m.y, revealed: m.piece)
            }
            return flip(x: m.x, y: m.y)
        }
        return play(fromX: m.x, fromY: m.y, toX: m.tx, toY: m.ty)
    }

    private func commitMove(_ move: Move) {
        var m = move
        m.seat = turn
        m.prevTurn = turn
        m.prevSeat1 = seatColor[1]
        m.prevSeat2 = seatColor[2]
        m.prevIdle = idlePliesValue
        m.piece = board[m.y][m.x]
        m.captured = board[m.ty][m.tx]

        board[m.ty][m.tx] = m.piece
        board[m.y][m.x] = BanqiGame.empty
        faceUp[m.ty][m.tx] = true
        faceUp[m.y][m.x] = false

        finishAction(m, progress: m.captured != BanqiGame.empty)
    }

    private func finishAction(_ m: Move, progress: Bool) {
        history.insert(m, at: 0)
        pliesValue += 1
        idlePliesValue = progress ? 0 : idlePliesValue + 1
        turn = 3 - turn
        positionKeys.append(positionKey)
        evaluateEnd()
    }

    /// 撤销最后一步；返回被撤销的着法，无历史时返回 nil。
    func undo() -> Move? {
        guard !history.isEmpty else {
            return nil
        }
        let m = history.removeFirst()
        if m.flip {
            board[m.y][m.x] = m.prevBoard
            faceUp[m.y][m.x] = false
        } else {
            board[m.y][m.x] = m.piece
            board[m.ty][m.tx] = m.captured
            faceUp[m.y][m.x] = true
            faceUp[m.ty][m.tx] = m.captured != BanqiGame.empty
        }
        seatColor[1] = m.prevSeat1
        seatColor[2] = m.prevSeat2
        turn = m.prevTurn
        idlePliesValue = m.prevIdle
        pliesValue = max(0, pliesValue - 1)
        resultValue = BanqiGame.resultNone
        endReasonValue = ""
        endReasonKindValue = .none
        if !positionKeys.isEmpty {
            positionKeys.removeLast()
        }
        return m
    }

    // MARK: - 终局判定

    /// 指定座位是否还有合法动作（可翻的暗子，或己方明子可走/可吃）。
    func hasAnyAction(_ seat: Int) -> Bool {
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                if board[y][x] != BanqiGame.empty && !faceUp[y][x] {
                    return true
                }
            }
        }
        let color = colorOfSeat(seat)
        return color != 0 && !movesForColor(color).isEmpty
    }

    /// 外部在摆盘/恢复快照后主动跑一次终局判定。
    func refreshEnd() {
        evaluateEnd()
    }

    private func evaluateEnd() {
        if resultValue != BanqiGame.resultNone {
            return
        }
        if !hasAnyAction(turn) {
            let loserColor = seatColor[turn]
            let winnerColor = seatColor[3 - turn]
            if winnerColor == 0 {
                resultValue = BanqiGame.resultDraw
                endReasonValue = "双方均无子可动，判和"
                endReasonKindValue = .mutualNoMoveDraw
            } else {
                resultValue = winnerColor
                endReasonValue = BanqiGame.colorName(winnerColor) + "方获胜 · "
                    + (loserColor == 0 ? "对方" : BanqiGame.colorName(loserColor) + "方") + "无子可动"
                endReasonKindValue = .noLegalMove(seat: turn)
            }
            return
        }
        let current = positionKeys.last ?? ""
        var repeat = 0
        for key in positionKeys where key == current {
            repeat += 1
        }
        if repeat >= BanqiGame.repeatDrawCount {
            resultValue = BanqiGame.resultDraw
            endReasonValue = "同一局面出现三次，判和"
            endReasonKindValue = .repeatDraw
            return
        }
        let idleLimit = BanqiOptions.drawIdlePlies > 0
            ? BanqiOptions.drawIdlePlies : BanqiGame.drawIdlePlies
        if idlePliesValue >= idleLimit {
            resultValue = BanqiGame.resultDraw
            endReasonValue = "连续 " + String(idleLimit) + " 步无吃子无翻子，判和"
            endReasonKindValue = .idleDraw
        }
    }

    /// 认输。与 Java 一致：颜色未定时判和。
    func resign(seat: Int) {
        if resultValue != BanqiGame.resultNone {
            return
        }
        finishBySeatLoss(seat: seat, verb: "认输", kind: .resign(seat: seat))
    }

    /// 超时判负。Java 侧复用 resign()，这里独立成 case，文案为「超时」。
    func timeout(seat: Int) {
        if resultValue != BanqiGame.resultNone {
            return
        }
        finishBySeatLoss(seat: seat, verb: "超时", kind: .timeout(seat: seat))
    }

    /// 断线判负。Java 侧同样复用 resign()，这里独立成 case。
    func disconnect(seat: Int) {
        if resultValue != BanqiGame.resultNone {
            return
        }
        finishBySeatLoss(seat: seat, verb: "断线", kind: .disconnect(seat: seat))
    }

    private func finishBySeatLoss(seat: Int, verb: String, kind: BanqiEndReason) {
        let loser = colorOfSeat(seat)
        let winner = colorOfSeat(3 - seat)
        if winner == 0 {
            resultValue = BanqiGame.resultDraw
            endReasonValue = verb + "（颜色未定），判和"
            endReasonKindValue = kind
            return
        }
        resultValue = winner
        endReasonValue = (loser == 0 ? "对方" : BanqiGame.colorName(loser) + "方") + verb + "，"
            + BanqiGame.colorName(winner) + "方胜"
        endReasonKindValue = kind
    }

    func agreeDraw() {
        if resultValue == BanqiGame.resultNone {
            resultValue = BanqiGame.resultDraw
            endReasonValue = "双方同意和棋"
            endReasonKindValue = .agreedDraw
        }
    }

    func winnerSeat() -> Int {
        let color = resultValue
        return (color == BanqiGame.red || color == BanqiGame.black) ? seatOfColor(color) : 0
    }

    // MARK: - 暗子池与局面键

    /// 剩余暗子的身份计数（下标为编码 1..15）；联机镜像返回 nil。
    func unseenPool() -> [Int]? {
        if !fullSetKnown {
            return nil
        }
        var pool = [Int](repeating: 0, count: 16)
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                let p = board[y][x]
                if p > 0 && !faceUp[y][x] {
                    pool[p] += 1
                }
            }
        }
        for p in 1..<pool.count {
            if pool[p] > 0 && BanqiGame.typeOf(p) < 0 {
                return nil
            }
        }
        return pool
    }

    /// 局面键：只含明面、暗子位置、轮次、座位颜色；不含暗子身份。
    var positionKey: String {
        var sb = ""
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                let p = board[y][x]
                if p == BanqiGame.empty {
                    sb.append(".")
                } else if !faceUp[y][x] {
                    sb.append("x")
                } else {
                    sb.append(BanqiGame.fenChar(p))
                }
            }
            if y < BanqiGame.rows - 1 {
                sb.append("/")
            }
        }
        sb.append("|")
        sb.append(String(turn))
        sb.append("|")
        sb.append(String(seatColor[1]))
        sb.append(String(seatColor[2]))
        return sb
    }

    /// 联机快照/镜像 FEN：
    /// `xxxxxxxx/xxxxxxxx/xxxxxxxx/xxxxxxxx 1 -- 0 0 0`
    /// 依次为：棋盘、轮次座位、两座位颜色（r/b/-）、idle、ply、result。
    /// 暗子一律写作 x，不泄漏身份。
    var fen: String {
        var sb = ""
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                let p = board[y][x]
                if p == BanqiGame.empty {
                    sb.append(".")
                } else if !faceUp[y][x] {
                    sb.append("x")
                } else {
                    sb.append(BanqiGame.fenChar(p))
                }
            }
            if y < BanqiGame.rows - 1 {
                sb.append("/")
            }
        }
        sb.append(" ")
        sb.append(String(turn))
        sb.append(" ")
        sb.append(seatColor[1] == 0 ? "-" : (seatColor[1] == BanqiGame.red ? "r" : "b"))
        sb.append(seatColor[2] == 0 ? "-" : (seatColor[2] == BanqiGame.red ? "r" : "b"))
        sb.append(" ")
        sb.append(String(idlePliesValue))
        sb.append(" ")
        sb.append(String(pliesValue))
        sb.append(" ")
        sb.append(String(resultValue))
        return sb
    }

    /// 从 fen 恢复；暗子身份未知，fullSetKnown 置为 false。
    func loadFen(_ fen: String) -> Bool {
        let parts = fen.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        if parts.count < 6 {
            return false
        }
        let rows = parts[0].split(separator: "/").map(String.init)
        if rows.count != BanqiGame.rows {
            return false
        }
        var next = Array(
            repeating: Array(repeating: BanqiGame.empty, count: BanqiGame.cols),
            count: BanqiGame.rows
        )
        var nextUp = Array(
            repeating: Array(repeating: false, count: BanqiGame.cols),
            count: BanqiGame.rows
        )
        for y in 0..<BanqiGame.rows {
            if rows[y].count != BanqiGame.cols {
                return false
            }
            for (x, c) in rows[y].enumerated() {
                if c == "." {
                    next[y][x] = BanqiGame.empty
                } else if c == "x" {
                    next[y][x] = BanqiGame.hidden
                } else {
                    let p = BanqiGame.decodeFenChar(c)
                    if p == BanqiGame.empty {
                        return false
                    }
                    next[y][x] = p
                    nextUp[y][x] = true
                }
            }
        }
        guard let parsedTurn = Int(parts[1]) else { return false }
        guard parts[2].count >= 2 else { return false }
        let colors = Array(parts[2])
        let parsedSeat1 = BanqiGame.parseColorChar(colors[0])
        let parsedSeat2 = BanqiGame.parseColorChar(colors[1])
        guard let parsedIdle = Int(parts[3]),
              let parsedPlies = Int(parts[4]),
              let parsedResult = Int(parts[5]) else {
            return false
        }

        turn = parsedTurn == BanqiGame.seatSecond ? BanqiGame.seatSecond : BanqiGame.seatFirst
        seatColor[1] = parsedSeat1
        seatColor[2] = parsedSeat2
        idlePliesValue = max(0, parsedIdle)
        pliesValue = max(0, parsedPlies)
        resultValue = parsedResult
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                board[y][x] = next[y][x]
                faceUp[y][x] = nextUp[y][x]
            }
        }
        fullSetKnown = false
        endReasonValue = ""
        endReasonKindValue = .none
        history.removeAll()
        positionKeys.removeAll()
        positionKeys.append(positionKey)
        return true
    }

    // MARK: - 展示

    func notation(_ m: Move) -> String {
        if m.flip {
            return "翻 " + BanqiGame.coord(m.x, m.y) + " "
                + BanqiGame.colorName(BanqiGame.colorOf(m.piece)) + BanqiGame.pieceName(m.piece)
        }
        var sb = BanqiGame.colorName(BanqiGame.colorOf(m.piece)) + BanqiGame.pieceName(m.piece)
        sb += " " + BanqiGame.coord(m.x, m.y) + "→" + BanqiGame.coord(m.tx, m.ty)
        if m.captured != BanqiGame.empty {
            sb += " 吃 " + BanqiGame.colorName(BanqiGame.colorOf(m.captured)) + BanqiGame.pieceName(m.captured)
        }
        return sb
    }

    private static func fenChar(_ p: Int) -> Character {
        let c = BanqiGame.fenChars[BanqiGame.typeOf(p)]
        if BanqiGame.colorOf(p) == BanqiGame.red {
            return Character(String(c).uppercased())
        }
        return c
    }

    private static func decodeFenChar(_ c: Character) -> Int {
        let lower = Character(String(c).lowercased())
        for (type, ch) in BanqiGame.fenChars.enumerated() where ch == lower {
            return BanqiGame.piece(color: c.isUppercase ? BanqiGame.red : BanqiGame.black, type: type)
        }
        return BanqiGame.empty
    }

    private static func parseColorChar(_ c: Character) -> Int {
        if c == "r" || c == "R" { return BanqiGame.red }
        if c == "b" || c == "B" { return BanqiGame.black }
        return 0
    }
}

/// `java.util.Random` 的逐位等价实现（48 位 LCG）。
/// 保证同一 seed 下洗牌结果与 Android 完全一致。
struct BanqiJavaRandom {

    private static let multiplier: UInt64 = 0x5DEECE66D
    private static let addend: UInt64 = 0xB
    private static let mask: UInt64 = (1 << 48) - 1

    private var seed: UInt64

    init(seed: Int64) {
        self.seed = (UInt64(bitPattern: seed) ^ BanqiJavaRandom.multiplier) & BanqiJavaRandom.mask
    }

    /// java.util.Random.next(bits)
    mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* BanqiJavaRandom.multiplier &+ BanqiJavaRandom.addend) & BanqiJavaRandom.mask
        if bits == 32 {
            return Int32(bitPattern: UInt32(truncatingIfNeeded: seed >> 16))
        }
        return Int32(seed >> UInt64(48 - bits))
    }

    /// java.util.Random.nextInt(bound)
    mutating func nextInt(_ bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        let r = Int(next(31))
        let m = bound - 1
        if (bound & m) == 0 {
            // bound 是 2 的幂
            return Int((Int64(bound) * Int64(r)) >> 31)
        }
        var u = r
        while true {
            let value = u % bound
            // Java 用 int 做 `u - (r = u % bound) + m`，溢出会回绕为负数并重试。
            let check = Int32(truncatingIfNeeded: Int64(u) - Int64(value) + Int64(m))
            if check >= 0 {
                return value
            }
            u = Int(next(31))
        }
    }

    /// java.util.Random.nextLong()
    mutating func nextLong() -> Int64 {
        (Int64(next(32)) &<< 32) &+ Int64(next(32))
    }
}
