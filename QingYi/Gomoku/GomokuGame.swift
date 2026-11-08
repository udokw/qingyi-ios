import Foundation

/// 移植自 Android `com.sijia.go.GomokuGame`
/// 源文件：app/src/main/java/com/sijia/go/GomokuGame.java（只读参考，未做任何修改）
///
/// 方法一一对应：
///   init(size:)                ← GomokuGame(int size)      size = max(5, min(25, size))
///   play(_:_:) / tryPlay       ← play / tryPlay
///   undo()                     ← undo
///   isWinningMove              ← isWinningMove
///   findWin                    ← findWin（四方向 {1,0}{0,1}{1,1}{1,-1} 顺序完全一致）
///   isForbidden / isForbiddenPoint / forbiddenAt
///   runThrough / dirHasFour / dirHasOpenThree / openFourThrough
///   copyBoard                  ← copyBoard
///
/// 棋盘用扁平 [Int]：0 空 / 1 黑 / 2 白，下标 = y * size + x，对应 Java 的 board[y][x]。
/// (0,0) 在左上角；x 向右（列），y 向下（行）。黑先。
final class GomokuGame {
    // 与 Java 常量同值
    static let empty = 0
    static let black = 1
    static let white = 2
    static let boardSize = 19

    static let playOK = 0
    static let playOccupied = 1
    static let playOver = 2
    static let playForbidden = 3

    static let forbidNone = 0
    static let forbidOverline = 1
    static let forbidDoubleFour = 2
    static let forbidDoubleThree = 3

    /// 一手棋：{color, x, y}，对应 Java 的 int[]{color, x, y}
    struct Move: Equatable {
        var color: Int
        var x: Int
        var y: Int
    }

    /// 获胜五连的首尾坐标，对应 Java 的 int[]{x1, y1, x2, y2}
    struct WinLine: Equatable {
        var x1: Int
        var y1: Int
        var x2: Int
        var y2: Int
    }

    let size: Int
    private(set) var board: [Int]
    private(set) var history: [Move] = []
    private(set) var turn = GomokuGame.black
    private(set) var winner = GomokuGame.empty
    /// 连珠禁手（仅黑棋）：长连 / 四四 / 三三。默认关闭 = freestyle。
    var isRenju = false
    private(set) var winLine: WinLine?
    private(set) var lastX = -1
    private(set) var lastY = -1

    init(size: Int = GomokuGame.boardSize) {
        let n = max(5, min(25, size))
        self.size = n
        self.board = Array(repeating: GomokuGame.empty, count: n * n)
    }

    var moveCount: Int { history.count }
    var canUndo: Bool { !history.isEmpty }
    var isOver: Bool { winner != GomokuGame.empty }

    /// 扁平数组下标，等价于 Java 的 board[y][x] 的地址。
    func index(_ x: Int, _ y: Int) -> Int { y * size + x }

    func get(_ x: Int, _ y: Int) -> Int {
        if x < 0 || y < 0 || x >= size || y >= size { return GomokuGame.empty }
        return board[y * size + x]
    }

    func isEmpty(_ x: Int, _ y: Int) -> Bool { get(x, y) == GomokuGame.empty }

    func clear() {
        for i in 0..<board.count { board[i] = GomokuGame.empty }
        history.removeAll()
        turn = GomokuGame.black
        winner = GomokuGame.empty
        winLine = nil
        lastX = -1
        lastY = -1
    }

    /// 当前方落子；非法或已结束返回 false。
    @discardableResult
    func play(_ x: Int, _ y: Int) -> Bool {
        tryPlay(x, y) == GomokuGame.playOK
    }

    /// 带原因码的落子。禁手模式下黑棋落禁手点返回 playForbidden 且棋局不变。
    /// 成五优先：同一手若已形成五连，即使别处同时出现长连也判胜，不算禁手。
    @discardableResult
    func tryPlay(_ x: Int, _ y: Int) -> Int {
        if winner != GomokuGame.empty { return GomokuGame.playOver }
        if x < 0 || y < 0 || x >= size || y >= size { return GomokuGame.playOccupied }
        if board[y * size + x] != GomokuGame.empty { return GomokuGame.playOccupied }
        let color = turn
        if isRenju && color == GomokuGame.black {
            if GomokuGame.forbiddenAt(&board, size, x, y) != GomokuGame.forbidNone {
                return GomokuGame.playForbidden
            }
        }
        board[y * size + x] = color
        history.append(Move(color: color, x: x, y: y))
        lastX = x
        lastY = y
        if let line = findWin(x, y, color) {
            winner = color
            winLine = line
        } else {
            turn = 3 - color
        }
        return GomokuGame.playOK
    }

    /// 悔一手；返回是否有子可悔。
    func undo() -> Bool {
        guard let last = history.popLast() else { return false }
        board[last.y * size + last.x] = GomokuGame.empty
        turn = last.color
        winner = GomokuGame.empty
        winLine = nil
        if let prev = history.last {
            lastX = prev.x
            lastY = prev.y
        } else {
            lastX = -1
            lastY = -1
        }
        return true
    }

    func isFull() -> Bool {
        for v in board where v == GomokuGame.empty { return false }
        return true
    }

    /// 以 (x,y) 落子后是否五连；不修改棋局。
    func isWinningMove(_ x: Int, _ y: Int, _ color: Int) -> Bool {
        if x < 0 || y < 0 || x >= size || y >= size { return false }
        if board[y * size + x] != GomokuGame.empty { return false }
        return findWin(x, y, color) != nil
    }

    private static let dirs: [(Int, Int)] = [(1, 0), (0, 1), (1, 1), (1, -1)]

    /// 返回包含 (x,y) 的五连首尾坐标，没有则 nil。
    private func findWin(_ x: Int, _ y: Int, _ color: Int) -> WinLine? {
        for d in GomokuGame.dirs {
            var x1 = x, y1 = y, x2 = x, y2 = y
            while inBounds(x1 - d.0, y1 - d.1) && board[(y1 - d.1) * size + (x1 - d.0)] == color {
                x1 -= d.0
                y1 -= d.1
            }
            while inBounds(x2 + d.0, y2 + d.1) && board[(y2 + d.1) * size + (x2 + d.0)] == color {
                x2 += d.0
                y2 += d.1
            }
            let count = max(abs(x2 - x1), abs(y2 - y1)) + 1
            if count >= 5 {
                return WinLine(x1: x1, y1: y1, x2: x2, y2: y2)
            }
        }
        return nil
    }

    private func inBounds(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < size && y < size
    }

    // ---------------- 连珠禁手（黑棋） ----------------

    /// 当前棋盘上黑棋落 (x,y) 是否禁手；未开启禁手时恒为 false。
    func isForbidden(_ x: Int, _ y: Int) -> Bool {
        guard isRenju else { return false }
        return GomokuGame.forbiddenAt(&board, size, x, y) != GomokuGame.forbidNone
    }

    /// 任意棋盘副本上黑棋落 (x,y) 是否禁手（AI 计算时用，不改动原棋局）。
    static func isForbiddenPoint(_ board: [Int], size: Int, x: Int, y: Int) -> Bool {
        var bd = board
        return forbiddenAt(&bd, size, x, y) != forbidNone
    }

    /// 禁手类型文案；非禁手返回空串。
    func forbiddenText(_ x: Int, _ y: Int) -> String {
        switch GomokuGame.forbiddenAt(&board, size, x, y) {
        case GomokuGame.forbidOverline:
            return "长连禁手（黑棋不能连成六子及以上）"
        case GomokuGame.forbidDoubleFour:
            return "四四禁手（黑棋不能同时形成两个四）"
        case GomokuGame.forbidDoubleThree:
            return "三三禁手（黑棋不能同时形成两个活三）"
        default:
            return ""
        }
    }

    /// 标准连珠禁手判定（只针对黑棋）：
    /// 长连（同方向连续 >=6）；四四（两个方向各能成五）；三三（两个方向各能成活四）。
    /// 若该手本身已成五，判为合法胜着。
    private static func forbiddenAt(_ bd: inout [Int], _ n: Int, _ x: Int, _ y: Int) -> Int {
        if x < 0 || y < 0 || x >= n || y >= n { return forbidNone }
        if bd[y * n + x] != empty { return forbidNone }
        bd[y * n + x] = black
        defer { bd[y * n + x] = empty }

        var five = false
        var overline = false
        var fours = 0
        var threes = 0
        for d in GomokuGame.dirs {
            let cnt = runThrough(bd, n, x, y, d.0, d.1, black)
            if cnt == 5 {
                five = true
            } else if cnt > 5 {
                overline = true
            }
            if dirHasFour(&bd, n, x, y, d.0, d.1) {
                fours += 1
            } else if dirHasOpenThree(&bd, n, x, y, d.0, d.1) {
                threes += 1
            }
        }
        if five { return forbidNone }
        if overline { return forbidOverline }
        if fours >= 2 { return forbidDoubleFour }
        if threes >= 2 { return forbidDoubleThree }
        return forbidNone
    }

    /// 以 (x,y) 为中心，指定方向上的连续同色子数（含自身）。
    private static func runThrough(_ bd: [Int], _ n: Int, _ x: Int, _ y: Int,
                                   _ dx: Int, _ dy: Int, _ color: Int) -> Int {
        var cnt = 1
        var cx = x + dx
        var cy = y + dy
        while cx >= 0 && cy >= 0 && cx < n && cy < n && bd[cy * n + cx] == color {
            cnt += 1
            cx += dx
            cy += dy
        }
        cx = x - dx
        cy = y - dy
        while cx >= 0 && cy >= 0 && cx < n && cy < n && bd[cy * n + cx] == color {
            cnt += 1
            cx -= dx
            cy -= dy
        }
        return cnt
    }

    /// 该方向是否存在一个空点，补上黑子后能成五（即已构成一个「四」）。
    private static func dirHasFour(_ bd: inout [Int], _ n: Int, _ x: Int, _ y: Int,
                                   _ dx: Int, _ dy: Int) -> Bool {
        for s in -4...4 {
            if s == 0 { continue }
            let qx = x + dx * s
            let qy = y + dy * s
            if qx < 0 || qy < 0 || qx >= n || qy >= n || bd[qy * n + qx] != empty { continue }
            bd[qy * n + qx] = black
            let four = runThrough(bd, n, x, y, dx, dy, black) == 5
            bd[qy * n + qx] = empty
            if four { return true }
        }
        return false
    }

    /// 该方向是否存在一个空点，补上后能形成「活四」（即当前是活三）。
    private static func dirHasOpenThree(_ bd: inout [Int], _ n: Int, _ x: Int, _ y: Int,
                                        _ dx: Int, _ dy: Int) -> Bool {
        for s in -4...4 {
            if s == 0 { continue }
            let qx = x + dx * s
            let qy = y + dy * s
            if qx < 0 || qy < 0 || qx >= n || qy >= n || bd[qy * n + qx] != empty { continue }
            bd[qy * n + qx] = black
            let three = openFourThrough(bd, n, x, y, dx, dy)
            bd[qy * n + qx] = empty
            if three { return true }
        }
        return false
    }

    /// (x,y) 所在方向是否恰好是「活四」：连续 4 子且两端皆空。
    private static func openFourThrough(_ bd: [Int], _ n: Int, _ x: Int, _ y: Int,
                                        _ dx: Int, _ dy: Int) -> Bool {
        if runThrough(bd, n, x, y, dx, dy, black) != 4 { return false }
        var x1 = x, y1 = y, x2 = x, y2 = y
        while x1 - dx >= 0 && y1 - dy >= 0 && x1 - dx < n && y1 - dy < n
            && bd[(y1 - dy) * n + (x1 - dx)] == black {
            x1 -= dx
            y1 -= dy
        }
        while x2 + dx >= 0 && y2 + dy >= 0 && x2 + dx < n && y2 + dy < n
            && bd[(y2 + dy) * n + (x2 + dx)] == black {
            x2 += dx
            y2 += dy
        }
        let ax = x1 - dx, ay = y1 - dy, bx = x2 + dx, by = y2 + dy
        return ax >= 0 && ay >= 0 && ax < n && ay < n && bd[ay * n + ax] == empty
            && bx >= 0 && by >= 0 && bx < n && by < n && bd[by * n + bx] == empty
    }

    /// AI 用的棋盘副本。
    func copyBoard() -> [Int] { board }
}
