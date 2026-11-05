import Foundation

/// 围棋颜色: 0 空 / 1 黑 / 2 白
enum GoColor: Int {
    case empty = 0
    case black = 1
    case white = 2

    var opposite: GoColor {
        switch self {
        case .black: return .white
        case .white: return .black
        case .empty: return .empty
        }
    }
}

struct GoPoint: Hashable {
    var x: Int
    var y: Int

    static func == (lhs: GoPoint, rhs: GoPoint) -> Bool { lhs.x == rhs.x && lhs.y == rhs.y }
}

struct GoMove {
    /// nil 表示 PASS
    var point: GoPoint?
    var color: GoColor
    var captured: [GoPoint] = []
    /// 落子前的劫点, 用于悔棋恢复
    var koPoint: GoPoint?
}

/// 围棋棋局: 落子/提子/打劫/悔棋/中国规则数子
/// 坐标 (0,0) 为左上角, x 向右, y 向下
final class GoGame {
    static let defaultSize = 19

    let size: Int
    private(set) var board: [[GoColor]]
    private(set) var history: [GoMove] = []
    private(set) var ko: GoPoint?
    private(set) var turn: GoColor = .black
    private(set) var handicap: Int = 0
    var komi: Double = 7.5

    init(size: Int = GoGame.defaultSize) {
        self.size = max(2, min(25, size))
        self.board = Array(repeating: Array(repeating: .empty, count: self.size), count: self.size)
    }

    // MARK: - 基础查询
    var moveCount: Int { history.filter { $0.color != .empty }.count }
    var canUndo: Bool { !history.isEmpty }

    func colorAt(_ x: Int, _ y: Int) -> GoColor {
        guard x >= 0, x < size, y >= 0, y < size else { return .empty }
        return board[y][x]
    }

    // MARK: - 初始化

    func clear() {
        for y in 0..<size {
            for x in 0..<size { board[y][x] = .empty }
        }
        history.removeAll()
        ko = nil
        turn = .black
        handicap = 0
    }

    /// 摆让子(不改变先后手, 让子后白先)
    func placeHandicap(_ points: [GoPoint]) {
        for p in points where p.x >= 0 && p.x < size && p.y >= 0 && p.y < size {
            board[p.y][p.x] = .black
        }
        handicap = points.count
        if handicap > 0 { turn = .white }
        history.removeAll()
        ko = nil
    }

    /// 棋谱摆子(AB/AW/AE): 黑/白固定子 + 清空点, 并指定行棋方
    func setup(black: [GoPoint], white: [GoPoint], empty: [GoPoint], toMove: GoColor) {
        clear()
        for p in empty where inBounds(p) { board[p.y][p.x] = .empty }
        for p in black where inBounds(p) { board[p.y][p.x] = .black }
        for p in white where inBounds(p) { board[p.y][p.x] = .white }
        handicap = black.count
        if toMove == .black || toMove == .white {
            turn = toMove
        } else {
            turn = handicap > 0 ? .white : .black
        }
    }

    // MARK: - 合法性

    func isLegal(_ x: Int, _ y: Int, color: GoColor) -> Bool {
        guard inBounds(GoPoint(x: x, y: y)) else { return false }
        guard board[y][x] == .empty else { return false }
        if let k = ko, k.x == x, k.y == y { return false }
        return hasLibertyAfterPlay(x, y, color: color)
    }

    private func hasLibertyAfterPlay(_ x: Int, _ y: Int, color: GoColor) -> Bool {
        let enemy = color.opposite
        for d in GoGame.dirs {
            let nx = x + d.0, ny = y + d.1
            if inBounds(GoPoint(x: nx, y: ny)), board[ny][nx] == enemy {
                var seen = Set<Int>()
                if liberties(nx, ny, seen: &seen) == 1 { return true }
            }
        }
        board[y][x] = color
        var seen = Set<Int>()
        let lib = liberties(x, y, seen: &seen)
        board[y][x] = .empty
        return lib > 0
    }

    // MARK: - 落子

    /// 当前方落子, 返回 nil 表示非法手
    func play(_ x: Int, _ y: Int) -> GoMove? {
        guard isLegal(x, y, color: turn) else { return nil }
        var move = GoMove(point: GoPoint(x: x, y: y), color: turn, captured: [], koPoint: ko)
        board[y][x] = turn
        let enemy = turn.opposite
        for d in GoGame.dirs {
            let nx = x + d.0, ny = y + d.1
            guard inBounds(GoPoint(x: nx, y: ny)), board[ny][nx] == enemy else { continue }
            var seen = Set<Int>()
            if liberties(nx, ny, seen: &seen) == 0 {
                let group = capture(nx, ny, color: enemy)
                move.captured.append(contentsOf: group)
            }
        }
        // 单劫检测: 只提一子且自身也只有一气
        ko = nil
        var seen = Set<Int>()
        if move.captured.count == 1,
           liberties(x, y, seen: &seen) == 1,
           groupSize(x, y) == 1 {
            ko = move.captured[0]
        }
        history.append(move)
        turn = turn.opposite
        return move
    }

    func pass() -> GoMove {
        let move = GoMove(point: nil, color: turn, captured: [], koPoint: ko)
        ko = nil
        history.append(move)
        turn = turn.opposite
        return move
    }

    /// 悔一手, 返回被悔的着法
    func undo() -> GoMove? {
        guard let move = history.popLast() else { return nil }
        ko = move.koPoint
        if let p = move.point {
            board[p.y][p.x] = .empty
            for c in move.captured { board[c.y][c.x] = move.color.opposite }
        }
        turn = move.color
        return move
    }

    // MARK: - 数子

    /// 中国规则数子 (子空皆地, 不含贴目)
    func chineseScore() -> (black: Double, white: Double) {
        var owner = board
        var visited = Array(repeating: Array(repeating: false, count: size), count: size)
        var black = 0.0, white = 0.0

        for y in 0..<size {
            for x in 0..<size {
                guard board[y][x] == .empty, !visited[y][x] else { continue }
                var region: [GoPoint] = []
                var adjacent = Set<GoColor>()
                var queue: [GoPoint] = [GoPoint(x: x, y: y)]
                visited[y][x] = true
                var head = 0
                while head < queue.count {
                    let p = queue[head]; head += 1
                    region.append(p)
                    for d in GoGame.dirs {
                        let nx = p.x + d.0, ny = p.y + d.1
                        guard inBounds(GoPoint(x: nx, y: ny)) else { continue }
                        if board[ny][nx] == .empty {
                            if !visited[ny][nx] {
                                visited[ny][nx] = true
                                queue.append(GoPoint(x: nx, y: ny))
                            }
                        } else {
                            adjacent.insert(board[ny][nx])
                        }
                    }
                }
                if adjacent.count == 1, let c = adjacent.first {
                    for p in region { owner[p.y][p.x] = c }
                }
            }
        }

        for y in 0..<size {
            for x in 0..<size {
                if owner[y][x] == .black { black += 1 }
                else if owner[y][x] == .white { white += 1 }
            }
        }
        return (black, white)
    }

    /// 地域归属(供形势显示): 0 无主 / 1 黑 / 2 白
    func territoryMap() -> [[Int]] {
        var ownership = Array(repeating: Array(repeating: 0, count: size), count: size)
        var visited = Array(repeating: Array(repeating: false, count: size), count: size)
        for y in 0..<size {
            for x in 0..<size {
                guard board[y][x] == .empty, !visited[y][x] else { continue }
                var adjacent = Set<GoColor>()
                var queue: [GoPoint] = [GoPoint(x: x, y: y)]
                var region: [GoPoint] = []
                visited[y][x] = true
                var head = 0
                while head < queue.count {
                    let p = queue[head]; head += 1
                    region.append(p)
                    for d in GoGame.dirs {
                        let nx = p.x + d.0, ny = p.y + d.1
                        guard inBounds(GoPoint(x: nx, y: ny)) else { continue }
                        if board[ny][nx] == .empty {
                            if !visited[ny][nx] {
                                visited[ny][nx] = true
                                queue.append(GoPoint(x: nx, y: ny))
                            }
                        } else {
                            adjacent.insert(board[ny][nx])
                        }
                    }
                }
                if adjacent.count == 1, let c = adjacent.first {
                    for p in region { ownership[p.y][p.x] = c.rawValue }
                }
            }
        }
        return ownership
    }

    // MARK: - 坐标转换

    private static let gtpCols = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")

    /// (x,y) -> GTP 顶点, 如 19 路 (3,3) -> "Q16"
    func toGtp(_ x: Int, _ y: Int) -> String {
        guard x >= 0, x < GoGame.gtpCols.count else { return "pass" }
        return "\(GoGame.gtpCols[x])\(size - y)"
    }

    /// GTP 顶点 -> (x,y); "PASS"/"RESIGN" 返回 nil
    func fromGtp(_ vertex: String) -> GoPoint? {
        let v = vertex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if v == "PASS" || v == "RESIGN" { return nil }
        guard let first = v.first, let idx = GoGame.gtpCols.firstIndex(of: first) else { return nil }
        let digits = v.dropFirst().filter { $0.isNumber }
        guard let num = Int(digits) else { return nil }
        let y = size - num
        guard y >= 0, y < size else { return nil }
        return GoPoint(x: idx, y: y)
    }

    static func toSgf(_ x: Int, _ y: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String(letters[max(0, min(25, x))]) + String(letters[max(0, min(25, y))])
    }

    static func fromSgf(_ s: String) -> GoPoint? {
        let chars = Array(s)
        guard chars.count >= 2,
              let cx = chars[0].asciiValue, let cy = chars[1].asciiValue else { return nil }
        return GoPoint(x: Int(cx) - 97, y: Int(cy) - 97)
    }

    /// GTP 让子列表 -> 坐标
    func parseVertices(_ text: String) -> [GoPoint] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { fromGtp(String($0)) }
    }

    // MARK: - 内部

    static let dirs: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    private func inBounds(_ p: GoPoint) -> Bool {
        p.x >= 0 && p.x < size && p.y >= 0 && p.y < size
    }

    private func key(_ x: Int, _ y: Int) -> Int { y * size + x }

    private func liberties(_ x: Int, _ y: Int, seen: inout Set<Int>) -> Int {
        let color = board[y][x]
        guard color != .empty else { return 0 }
        var libs = 0
        var queue: [GoPoint] = [GoPoint(x: x, y: y)]
        seen.insert(key(x, y))
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            for d in GoGame.dirs {
                let nx = p.x + d.0, ny = p.y + d.1
                guard inBounds(GoPoint(x: nx, y: ny)) else { continue }
                if board[ny][nx] == .empty {
                    libs += 1
                } else if board[ny][nx] == color, !seen.contains(key(nx, ny)) {
                    seen.insert(key(nx, ny))
                    queue.append(GoPoint(x: nx, y: ny))
                }
            }
        }
        return libs
    }

    private func groupSize(_ x: Int, _ y: Int) -> Int {
        let color = board[y][x]
        guard color != .empty else { return 0 }
        var seen: Set<Int> = [key(x, y)]
        var queue: [GoPoint] = [GoPoint(x: x, y: y)]
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            for d in GoGame.dirs {
                let nx = p.x + d.0, ny = p.y + d.1
                guard inBounds(GoPoint(x: nx, y: ny)), board[ny][nx] == color else { continue }
                if !seen.contains(key(nx, ny)) {
                    seen.insert(key(nx, ny))
                    queue.append(GoPoint(x: nx, y: ny))
                }
            }
        }
        return seen.count
    }

    private func capture(_ x: Int, _ y: Int, color: GoColor) -> [GoPoint] {
        var group: [GoPoint] = []
        var seen: Set<Int> = [key(x, y)]
        var queue: [GoPoint] = [GoPoint(x: x, y: y)]
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            board[p.y][p.x] = .empty
            group.append(p)
            for d in GoGame.dirs {
                let nx = p.x + d.0, ny = p.y + d.1
                guard inBounds(GoPoint(x: nx, y: ny)), board[ny][nx] == color else { continue }
                if !seen.contains(key(nx, ny)) {
                    seen.insert(key(nx, ny))
                    queue.append(GoPoint(x: nx, y: ny))
                }
            }
        }
        return group
    }
}

// MARK: - 中文数字

enum ChineseNumber {
    static func text(_ n: Int) -> String {
        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        if n <= 0 { return digits[0] }
        if n <= 10 { return n == 10 ? "十" : digits[n] }
        if n < 20 { return "十" + digits[n - 10] }
        if n < 100 {
            let tens = digits[n / 10] + "十"
            return n % 10 == 0 ? tens : tens + digits[n % 10]
        }
        if n < 1000 {
            let hundreds = digits[n / 100] + "百"
            let rest = n % 100
            if rest == 0 { return hundreds }
            if rest < 10 { return hundreds + "零" + digits[rest] }
            return hundreds + text(rest)
        }
        return String(n)
    }
}
