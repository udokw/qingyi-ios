import Foundation

/// 中国象棋棋局与规则
/// 棋盘 9 列 × 10 行; (0,0) 为左上角, 红方在下(y=7..9), 黑方在上(y=0..2)
/// 覆盖: 马腿/象眼/炮架/过河兵/九宫/飞将, 将军/将死/困毙, 长将判负, 60 回合自然限着
final class XiangqiGame {
    static let cols = 9
    static let rows = 10

    enum Color: Int {
        case red = 1
        case black = 2
    }

    enum Kind: Int {
        case king = 0, advisor, elephant, horse, rook, cannon, pawn
    }

    struct Piece: Equatable {
        var color: Color
        var kind: Kind
    }

    struct Move {
        var from: GoPoint
        var to: GoPoint
        var piece: Piece?
        var captured: Piece?
        var color: Color = .red
        var prevNoCapture = 0

        var uci: String {
            let letters = Array("abcdefghi")
            return "\(letters[from.x])\(9 - from.y)\(letters[to.x])\(9 - to.y)"
        }
    }

    private(set) var board: [[Piece?]] = []
    private(set) var turn: Color = .red
    private(set) var history: [Move] = []
    private var positionKeys: [String] = []
    private var gaveCheck: [Bool] = []
    private var noCapturePlies = 0
    private(set) var result: Color? = nil
    private(set) var isDraw = false
    private(set) var endReason = ""

    init() { reset() }

    var isOver: Bool { result != nil || isDraw }
    var plies: Int { history.count }
    var lastMove: Move? { history.last }

    // MARK: - 初始化 / 局面

    func reset() {
        board = Array(repeating: Array(repeating: nil, count: XiangqiGame.cols), count: XiangqiGame.rows)
        let back: [Kind] = [.rook, .horse, .elephant, .advisor, .king, .advisor, .elephant, .horse, .rook]
        for x in 0..<XiangqiGame.cols {
            board[0][x] = Piece(color: .black, kind: back[x])
            board[9][x] = Piece(color: .red, kind: back[x])
        }
        board[2][1] = Piece(color: .black, kind: .cannon)
        board[2][7] = Piece(color: .black, kind: .cannon)
        board[7][1] = Piece(color: .red, kind: .cannon)
        board[7][7] = Piece(color: .red, kind: .cannon)
        for x in stride(from: 0, to: XiangqiGame.cols, by: 2) {
            board[3][x] = Piece(color: .black, kind: .pawn)
            board[6][x] = Piece(color: .red, kind: .pawn)
        }
        history.removeAll()
        positionKeys = [positionKey()]
        gaveCheck.removeAll()
        noCapturePlies = 0
        turn = .red
        result = nil
        isDraw = false
        endReason = ""
    }

    func loadFen(_ fen: String) -> Bool {
        let parts = fen.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let field = parts.first else { return false }
        let ranks = field.split(separator: "/").map(String.init)
        guard ranks.count == XiangqiGame.rows else { return false }
        var next = Array(repeating: Array(repeating: Optional<Piece>.none, count: XiangqiGame.cols), count: XiangqiGame.rows)
        for y in 0..<XiangqiGame.rows {
            var x = 0
            for ch in ranks[y] {
                if let d = ch.wholeNumberValue, ch.isNumber {
                    x += d
                } else {
                    guard let p = XiangqiGame.parseFenPiece(ch), x < XiangqiGame.cols else { return false }
                    next[y][x] = p
                    x += 1
                }
                if x > XiangqiGame.cols { return false }
            }
        }
        board = next
        turn = (parts.count > 1 && parts[1].lowercased() == "b") ? .black : .red
        history.removeAll()
        positionKeys = [positionKey()]
        gaveCheck.removeAll()
        noCapturePlies = 0
        result = nil
        isDraw = false
        endReason = ""
        return true
    }

    var fen: String {
        var parts: [String] = []
        for y in 0..<XiangqiGame.rows {
            var line = ""
            var empty = 0
            for x in 0..<XiangqiGame.cols {
                guard let p = board[y][x] else { empty += 1; continue }
                if empty > 0 { line += "\(empty)"; empty = 0 }
                line.append(XiangqiGame.fenChar(p))
            }
            if empty > 0 { line += "\(empty)" }
            parts.append(line)
        }
        let moveNo = history.count / 2 + 1
        return parts.joined(separator: "/") + " \(turn == .red ? "w" : "b") - - \(noCapturePlies) \(moveNo)"
    }

    func positionKey() -> String {
        var out = ""
        for y in 0..<XiangqiGame.rows {
            for x in 0..<XiangqiGame.cols {
                if let p = board[y][x] {
                    let idx = p.color.rawValue * 8 + p.kind.rawValue
                    out.append(XiangqiGame.alphabet[idx])
                } else {
                    out.append(XiangqiGame.alphabet[0])
                }
            }
        }
        out += "\(turn.rawValue)"
        return out
    }

    func piece(at x: Int, _ y: Int) -> Piece? {
        guard inBounds(x, y) else { return nil }
        return board[y][x]
    }

    func kingPosition(_ color: Color) -> GoPoint? {
        for y in 0..<XiangqiGame.rows {
            for x in 0..<XiangqiGame.cols {
                if let p = board[y][x], p.color == color, p.kind == .king {
                    return GoPoint(x: x, y: y)
                }
            }
        }
        return nil
    }

    // MARK: - 着法生成

    func legalMoves() -> [Move] { legalMoves(for: turn) }

    func legalMoves(for color: Color) -> [Move] {
        var out: [Move] = []
        for y in 0..<XiangqiGame.rows {
            for x in 0..<XiangqiGame.cols {
                guard let p = board[y][x], p.color == color else { continue }
                for m in pseudoMoves(x, y) {
                    var probe = m
                    apply(&probe)
                    let legal = !inCheck(color)
                    unapply(probe)
                    if legal { out.append(probe) }
                }
            }
        }
        return out
    }

    func legalMoves(from: GoPoint) -> [Move] {
        guard inBounds(from.x, from.y), let p = board[from.y][from.x], p.color == turn else { return [] }
        var out: [Move] = []
        for m in pseudoMoves(from.x, from.y) {
            var probe = m
            apply(&probe)
            let legal = !inCheck(turn)
            unapply(probe)
            if legal { out.append(probe) }
        }
        return out
    }

    private func pseudoMoves(_ x: Int, _ y: Int) -> [Move] {
        guard let p = board[y][x] else { return [] }
        var out: [Move] = []
        let c = p.color
        switch p.kind {
        case .king:
            for d in XiangqiGame.ortho {
                let nx = x + d.0, ny = y + d.1
                if inPalace(nx, ny, c) && (board[ny][nx] == nil || board[ny][nx]!.color != c) {
                    out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: nx, y: ny)))
                }
            }
        case .advisor:
            for d in XiangqiGame.diag {
                let nx = x + d.0, ny = y + d.1
                if inPalace(nx, ny, c) && (board[ny][nx] == nil || board[ny][nx]!.color != c) {
                    out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: nx, y: ny)))
                }
            }
        case .elephant:
            for d in XiangqiGame.diag {
                let nx = x + d.0 * 2, ny = y + d.1 * 2
                let ex = x + d.0, ey = y + d.1
                guard inBounds(nx, ny), !crossesRiver(nx, ny, c) else { continue }
                if board[ey][ex] == nil && (board[ny][nx] == nil || board[ny][nx]!.color != c) {
                    out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: nx, y: ny)))
                }
            }
        case .horse:
            for d in XiangqiGame.horseMoves {
                let nx = x + d.0, ny = y + d.1
                let lx = x + d.2, ly = y + d.3
                guard inBounds(nx, ny), board[ly][lx] == nil else { continue }
                if board[ny][nx] == nil || board[ny][nx]!.color != c {
                    out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: nx, y: ny)))
                }
            }
        case .rook:
            for d in XiangqiGame.ortho {
                var nx = x + d.0, ny = y + d.1
                while inBounds(nx, ny), board[ny][nx] == nil {
                    out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: nx, y: ny)))
                    nx += d.0; ny += d.1
                }
                if inBounds(nx, ny), board[ny][nx]!.color != c {
                    out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: nx, y: ny)))
                }
            }
        case .cannon:
            for d in XiangqiGame.ortho {
                var nx = x + d.0, ny = y + d.1
                while inBounds(nx, ny), board[ny][nx] == nil {
                    out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: nx, y: ny)))
                    nx += d.0; ny += d.1
                }
                if inBounds(nx, ny) {
                    nx += d.0; ny += d.1
                    while inBounds(nx, ny), board[ny][nx] == nil { nx += d.0; ny += d.1 }
                    if inBounds(nx, ny), board[ny][nx]!.color != c {
                        out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: nx, y: ny)))
                    }
                }
            }
        case .pawn:
            let forward = c == .red ? -1 : 1
            let fy = y + forward
            if inBounds(x, fy) && (board[fy][x] == nil || board[fy][x]!.color != c) {
                out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: x, y: fy)))
            }
            if crossedRiver(x, y, c) {
                for dx in [-1, 1] {
                    let nx = x + dx
                    if inBounds(nx, y) && (board[y][nx] == nil || board[y][nx]!.color != c) {
                        out.append(Move(from: GoPoint(x: x, y: y), to: GoPoint(x: nx, y: y)))
                    }
                }
            }
        }
        return out
    }

    // MARK: - 将军 / 飞将

    func inCheck(_ color: Color) -> Bool {
        guard let k = kingPosition(color) else { return false }
        if kingsFacing() { return true }
        let enemy: Color = color == .red ? .black : .red

        // 车 / 炮: 沿四条直线检测
        for d in XiangqiGame.ortho {
            var x = k.x + d.0, y = k.y + d.1
            var screenSeen = false
            while inBounds(x, y) {
                if let p = board[y][x] {
                    if !screenSeen {
                        if p.color == enemy && p.kind == .rook { return true }
                        screenSeen = true
                    } else {
                        if p.color == enemy && p.kind == .cannon { return true }
                        break
                    }
                }
                x += d.0; y += d.1
            }
        }

        // 马: 反向枚举可能的马位与马腿
        for d in XiangqiGame.horseMoves {
            let ax = k.x - d.0, ay = k.y - d.1
            let lx = ax + d.2, ly = ay + d.3
            guard inBounds(ax, ay), inBounds(lx, ly), board[ly][lx] == nil else { continue }
            if let p = board[ay][ax], p.color == enemy, p.kind == .horse { return true }
        }

        // 兵 / 卒
        let forwardY = enemy == .red ? k.y + 1 : k.y - 1
        if inBounds(k.x, forwardY), let p = board[forwardY][k.x],
           p.color == enemy, p.kind == .pawn { return true }
        for dx in [-1, 1] {
            if inBounds(k.x + dx, k.y), let p = board[k.y][k.x + dx],
               p.color == enemy, p.kind == .pawn { return true }
        }
        return false
    }

    func kingsFacing() -> Bool {
        guard let r = kingPosition(.red), let b = kingPosition(.black), r.x == b.x else { return false }
        let lo = min(r.y, b.y), hi = max(r.y, b.y)
        guard hi - lo >= 2 else { return false }
        for y in (lo + 1)..<hi where board[y][r.x] != nil { return false }
        return true
    }

    // MARK: - 落子 / 悔棋

    func play(from: GoPoint, to: GoPoint) -> Bool {
        guard !isOver else { return false }
        for m in legalMoves(from: from) where m.to == to {
            commit(m)
            return true
        }
        return false
    }

    func playUci(_ uci: String) -> Bool {
        guard let sq = XiangqiGame.parseUciSquares(uci) else { return false }
        let fr = sq.0.y, tr = sq.1.y
        // rank 10 只可能来自 1-based 坐标(Fairy 大棋盘 UCI)
        if fr == 10 || tr == 10 {
            guard fr >= 1, tr >= 1 else { return false }
            return play(from: GoPoint(x: sq.0.x, y: 10 - fr), to: GoPoint(x: sq.1.x, y: 10 - tr))
        }
        // 标准 ICCS / Pikafish: rank 0 = 红方底线
        if fr >= 0, fr <= 9, tr >= 0, tr <= 9,
           play(from: GoPoint(x: sq.0.x, y: 9 - fr), to: GoPoint(x: sq.1.x, y: 9 - tr)) {
            return true
        }
        if fr >= 1, tr >= 1 {
            return play(from: GoPoint(x: sq.0.x, y: 10 - fr), to: GoPoint(x: sq.1.x, y: 10 - tr))
        }
        return false
    }

    /// Fairy 的 1-based UCI(a1..i10) 转为标准 0-based(a0..i9)
    static func normalizeFairyUci(_ uci: String) -> String {
        guard let sq = parseUciSquares(uci) else { return uci }
        let fr = sq.0.y, tr = sq.1.y
        guard fr >= 1, fr <= 10, tr >= 1, tr <= 10 else { return uci }
        let letters = alphabet
        return "\(letters[sq.0.x])\(fr - 1)\(letters[sq.1.x])\(tr - 1)"
    }

    private static func parseUciSquares(_ uci: String) -> (GoPoint, GoPoint)? {
        let chars = Array(uci.lowercased())
        guard chars.count >= 4 else { return nil }
        guard let f1 = chars[0].asciiValue, f1 >= 97, f1 <= 105 else { return nil }
        var i = 1
        var r1 = 0
        var got = false
        while i < chars.count, chars[i].isNumber, let d = chars[i].wholeNumberValue {
            r1 = r1 * 10 + d; i += 1; got = true
        }
        guard got, i < chars.count else { return nil }
        let f2c = chars[i]; i += 1
        guard let f2 = f2c.asciiValue, f2 >= 97, f2 <= 105 else { return nil }
        var r2 = 0
        got = false
        while i < chars.count, chars[i].isNumber, let d = chars[i].wholeNumberValue {
            r2 = r2 * 10 + d; i += 1; got = true
        }
        guard got else { return nil }
        return (GoPoint(x: Int(f1) - 97, y: r1), GoPoint(x: Int(f2) - 97, y: r2))
    }

    /// UI 用的失手原因
    func illegalReason(from: GoPoint, to: GoPoint) -> String {
        guard inBounds(from.x, from.y) else { return "起点无效" }
        guard let p = board[from.y][from.x] else { return "这里没有棋子" }
        guard p.color == turn else { return "还没轮到这一方" }
        guard inBounds(to.x, to.y) else { return "落点无效" }
        var reachable = false
        for m in pseudoMoves(from.x, from.y) where m.to == to { reachable = true; break }
        guard reachable else { return "这枚棋子不能这样走" }
        var probe = Move(from: from, to: to)
        apply(&probe)
        let selfCheck = inCheck(turn)
        unapply(probe)
        return selfCheck ? "这一手会让自己的老将被将军" : "此着不合规则"
    }

    private func commit(_ m: Move) {
        var move = m
        apply(&move)
        move.color = turn
        move.prevNoCapture = noCapturePlies
        history.append(move)
        noCapturePlies = move.captured == nil ? noCapturePlies + 1 : 0
        turn = turn == .red ? .black : .red
        gaveCheck.append(inCheck(turn))
        if history.count == 1 { positionKeys.removeAll() }
        positionKeys.append(positionKey())
        evaluateEnd()
    }

    private func evaluateEnd() {
        let moves = legalMoves(for: turn)
        if moves.isEmpty {
            result = turn == .red ? .black : .red
            endReason = (turn == .red ? "红方" : "黑方") + (inCheck(turn) ? "被将死" : "无子可走(困毙)")
            return
        }
        if noCapturePlies >= 120 {
            isDraw = true
            endReason = "六十回合无吃子, 判和"
            return
        }
        guard let key = positionKeys.last else { return }
        let repeats = positionKeys.filter { $0 == key }.count
        if repeats >= 3 {
            if let side = repeatedCheckingSide() {
                result = side == .red ? .black : .red
                endReason = (side == .red ? "红方" : "黑方") + "长将, 判负"
            } else {
                isDraw = true
                endReason = "三次重复局面, 判和"
            }
        }
    }

    /// 最近连续 6 个半回合若一方每着都将军, 返回该方(长将)
    private func repeatedCheckingSide() -> Color? {
        guard history.count >= 6 else { return nil }
        let hs = Array(history.reversed())
        var redCheck = 0, blackCheck = 0
        for i in 0..<6 {
            guard gaveCheck.count - 1 - i >= 0 else { break }
            if gaveCheck[gaveCheck.count - 1 - i] {
                if hs[i].color == .red { redCheck += 1 } else { blackCheck += 1 }
            }
        }
        if redCheck == 3 && blackCheck == 0 { return .red }
        if blackCheck == 3 && redCheck == 0 { return .black }
        return nil
    }

    /// 应用着法, 同时把棋子/被吃子写入 move(供撤销)
    private func apply(_ m: inout Move) {
        m.piece = board[m.from.y][m.from.x]
        m.captured = board[m.to.y][m.to.x]
        board[m.to.y][m.to.x] = m.piece
        board[m.from.y][m.from.x] = nil
    }

    private func unapply(_ m: Move) {
        board[m.from.y][m.from.x] = m.piece
        board[m.to.y][m.to.x] = m.captured
    }

    /// 供 AI 搜索: 复制一份只保留局面的棋局
    func copyForSearch() -> XiangqiGame {
        let g = XiangqiGame()
        g.board = board
        g.turn = turn
        g.history = []
        g.positionKeys = [positionKey()]
        g.gaveCheck = []
        g.noCapturePlies = noCapturePlies
        return g
    }

    /// 供 AI 搜索: 直接应用/撤销(不写历史)
    func makeSearchMove(_ m: Move) -> Move {
        var move = m
        move.color = turn
        move.prevNoCapture = noCapturePlies
        apply(&move)
        noCapturePlies = move.captured == nil ? noCapturePlies + 1 : 0
        turn = turn == .red ? .black : .red
        return move
    }

    func unmakeSearchMove(_ m: Move) {
        unapply(m)
        noCapturePlies = m.prevNoCapture
        turn = m.color
    }

    @discardableResult
    func undo() -> Move? {
        guard let m = history.popLast() else { return nil }
        unapply(m)
        noCapturePlies = m.prevNoCapture
        turn = m.color
        if !gaveCheck.isEmpty { gaveCheck.removeLast() }
        if !positionKeys.isEmpty { positionKeys.removeLast() }
        result = nil
        isDraw = false
        endReason = ""
        return m
    }

    func resign(_ color: Color) {
        result = color == .red ? .black : .red
        endReason = (color == .red ? "红方" : "黑方") + "认输"
    }

    func agreeDraw() {
        isDraw = true
        endReason = "双方协议和棋"
    }

    // MARK: - 记谱

    /// 中文纵线记谱, 如 炮二平五 / 马8进7
    func notation(_ m: Move) -> String {
        guard let p = m.piece ?? board[m.from.y][m.from.x] else { return "" }
        let c = p.color, t = p.kind
        let name = XiangqiGame.pieceName(p)
        var origin = fileNumber(m.from.x, c)
        // 同线同兵种: 前/后/中
        var same: [Int] = []
        for y in 0..<XiangqiGame.rows {
            if y == m.from.y {
                same.append(y)
                continue
            }
            if let q = board[y][m.from.x], q == p, y != m.to.y { same.append(y) }
        }
        var prefix = ""
        if same.count > 1 {
            same.sort { c == .red ? $0 < $1 : $0 > $1 }
            if let idx = same.firstIndex(of: m.from.y) {
                if same.count == 2 { prefix = idx == 0 ? "前" : "后" }
                else if same.count == 3 { prefix = idx == 0 ? "前" : (idx == 1 ? "中" : "后") }
                else { prefix = idx == 0 ? "前" : "后" }
                origin = ""
            }
        }
        let action: String
        let dest: String
        if m.to.y == m.from.y {
            action = "平"
            dest = fileNumber(m.to.x, c)
        } else {
            let forward = c == .red ? m.to.y < m.from.y : m.to.y > m.from.y
            action = forward ? "进" : "退"
            if t == .horse || t == .elephant || t == .advisor {
                dest = fileNumber(m.to.x, c)
            } else {
                dest = XiangqiGame.number(abs(m.to.y - m.from.y), c)
            }
        }
        return prefix + name + origin + action + dest
    }

    static func pieceName(_ p: Piece) -> String {
        switch p.kind {
        case .king: return p.color == .red ? "帅" : "将"
        case .advisor: return p.color == .red ? "仕" : "士"
        case .elephant: return p.color == .red ? "相" : "象"
        case .horse: return "马"
        case .rook: return "車"
        case .cannon: return "炮"
        case .pawn: return p.color == .red ? "兵" : "卒"
        }
    }

    func fileNumber(_ x: Int, _ color: Color) -> String {
        // 红方从右往左 1-9(右下角为 1), 黑方从屏幕左侧往右 1-9
        XiangqiGame.number(color == .red ? 9 - x : x + 1, color)
    }

    private static func number(_ n: Int, _ color: Color) -> String {
        if color == .black { return String(n) }
        let cn = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        return n >= 0 && n <= 9 ? cn[n] : String(n)
    }

    // MARK: - 编码

    static let alphabet = Array("abcdefghijklmnopqrstuvw")

    private static func fenChar(_ p: Piece) -> Character {
        let c: Character
        switch p.kind {
        case .king: c = "k"
        case .advisor: c = "a"
        case .elephant: c = "b"
        case .horse: c = "n"
        case .rook: c = "r"
        case .cannon: c = "c"
        case .pawn: c = "p"
        }
        return p.color == .red ? Character(String(c).uppercased()) : c
    }

    private static func parseFenPiece(_ ch: Character) -> Piece? {
        let color: Color = ch.isUppercase ? .red : .black
        switch ch.lowercased() {
        case "k": return Piece(color: color, kind: .king)
        case "a": return Piece(color: color, kind: .advisor)
        case "b": return Piece(color: color, kind: .elephant)
        case "n": return Piece(color: color, kind: .horse)
        case "r": return Piece(color: color, kind: .rook)
        case "c": return Piece(color: color, kind: .cannon)
        case "p": return Piece(color: color, kind: .pawn)
        default: return nil
        }
    }

    // MARK: - 内部

    private static let ortho: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    private static let diag: [(Int, Int)] = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    /// {dx, dy, 马腿x, 马腿y}
    private static let horseMoves: [(Int, Int, Int, Int)] = [
        (1, -2, 0, -1), (-1, -2, 0, -1), (1, 2, 0, 1), (-1, 2, 0, 1),
        (2, -1, 1, 0), (2, 1, 1, 0), (-2, -1, -1, 0), (-2, 1, -1, 0)
    ]

    private func inBounds(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < XiangqiGame.cols && y >= 0 && y < XiangqiGame.rows
    }

    private func inPalace(_ x: Int, _ y: Int, _ color: Color) -> Bool {
        guard x >= 3, x <= 5 else { return false }
        return color == .red ? (y >= 7 && y <= 9) : (y >= 0 && y <= 2)
    }

    private func crossesRiver(_ x: Int, _ y: Int, _ color: Color) -> Bool {
        color == .red ? y <= 4 : y >= 5
    }

    private func crossedRiver(_ x: Int, _ y: Int, _ color: Color) -> Bool {
        color == .red ? y <= 4 : y >= 5
    }
}
