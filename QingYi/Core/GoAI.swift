import Foundation

/// 内置围棋 AI (10 档)
/// 采用棋形/气/提子/棋形弱点的启发式评估 + 难度噪声; 不依赖 KataGo 等外部引擎
enum GoAI {

    struct Candidate {
        var point: GoPoint
        var score: Double
    }

    /// 返回推荐着法; nil 表示 PASS
    static func bestMove(board source: [[GoColor]], size: Int, color: GoColor,
                         ko: GoPoint?, level rawLevel: Int, lastMove: GoPoint?) -> GoPoint? {
        let level = max(1, min(10, rawLevel))
        var candidates: [Candidate] = []
        let occupancy = source.reduce(0) { partial, row in
            partial + row.filter { $0 != .empty }.count
        }
        let emptyCount = size * size - occupancy

        // 开局: 空盘优先占星位
        if occupancy <= 4, level >= 2, let star = openingPoint(size: size, board: source) {
            return star
        }

        for y in 0..<size {
            for x in 0..<size {
                guard source[y][x] == .empty else { continue }
                if let k = ko, k.x == x, k.y == y { continue }
                guard let result = evaluate(board: source, size: size, x: x, y: y,
                                            color: color, lastMove: lastMove) else { continue }
                guard result.ownLiberties > 0 else { continue }
                if result.captured == 0, isTrueEye(board: source, size: size, x: x, y: y, color: color) {
                    continue
                }
                var score = result.score
                // 难度噪声: 低档更大
                let jitter = Double(11 - level) * 1.1
                score += Double.random(in: -jitter...jitter)
                candidates.append(Candidate(point: GoPoint(x: x, y: y), score: score))
            }
        }

        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.score > $1.score }

        // 低档棋力: 在前若干手中随机选取
        let pool: Int
        switch level {
        case 1: pool = min(candidates.count, 24)
        case 2: pool = min(candidates.count, 16)
        case 3: pool = min(candidates.count, 10)
        case 4: pool = min(candidates.count, 6)
        case 5: pool = min(candidates.count, 4)
        case 6: pool = min(candidates.count, 3)
        default: pool = 1
        }
        if pool > 1 {
            let top = Array(candidates.prefix(pool))
            let weights = top.enumerated().map { max(0.05, 1.0 / Double($0.offset + 1)) }
            let total = weights.reduce(0, +)
            var r = Double.random(in: 0..<total)
            for (idx, w) in weights.enumerated() {
                r -= w
                if r <= 0 { return top[idx].point }
            }
            return top[0].point
        }

        // 局面将满且最佳着法也不佳时 PASS
        if emptyCount > 0, occupancy > size * size * 3 / 4, candidates[0].score < 2, level >= 3 {
            return nil
        }
        return candidates[0].point
    }

    // MARK: - 评估

    private struct Evaluation {
        var score: Double
        var captured: Int
        var ownLiberties: Int
    }

    private static func evaluate(board: [[GoColor]], size: Int, x: Int, y: Int,
                                 color: GoColor, lastMove: GoPoint?) -> Evaluation? {
        var work = board
        let enemy = color.opposite
        work[y][x] = color

        // 提子
        var captured = 0
        for d in GoGame.dirs {
            let nx = x + d.0, ny = y + d.1
            guard inBounds(nx, ny, size), work[ny][nx] == enemy else { continue }
            var seen = Set<Int>()
            var group: [GoPoint]? = nil
            let libs = liberties(work, size: size, x: nx, y: ny, seen: &seen, group: &group)
            if libs == 0 {
                for p in group ?? [] { work[p.y][p.x] = .empty }
                captured += group?.count ?? 0
            }
        }

        var seenSelf = Set<Int>()
        var selfGroup: [GoPoint]? = nil
        let ownLibs = liberties(work, size: size, x: x, y: y, seen: &seenSelf, group: &selfGroup)
        guard ownLibs > 0 else { return nil }

        var score = Double(captured) * 13.0

        // 自身气
        if ownLibs == 1 {
            let stoneCount = selfGroup?.count ?? 1
            score -= 30.0 + Double(stoneCount) * 1.5
        } else {
            score += min(6.0, Double(ownLibs)) * 1.4
        }

        // 救活自己的弱棋 / 紧气对方
        for d in GoGame.dirs {
            let nx = x + d.0, ny = y + d.1
            guard inBounds(nx, ny, size) else { continue }
            let c = work[ny][nx]
            if c == color {
                var seen = Set<Int>()
                var dummy: [GoPoint]? = nil
                let libs = liberties(work, size: size, x: nx, y: ny, seen: &seen, group: &dummy)
                if libs == 2 { score += 2.0 }
                if libs == 1 { score += 6.0 }
            } else if c == enemy {
                var seen = Set<Int>()
                var dummy: [GoPoint]? = nil
                let libs = liberties(work, size: size, x: nx, y: ny, seen: &seen, group: &dummy)
                if libs == 1 { score += 5.0 }
            }
        }

        // 行棋方向: 靠近上一手
        if let last = lastMove {
            let dist = abs(last.x - x) + abs(last.y - y)
            if dist <= 8 { score += Double(8 - dist) * 0.55 }
        }

        // 线位偏好(三、四线)
        let edge = min(min(x, size - 1 - x), min(y, size - 1 - y))
        switch edge {
        case 0: score -= 3.0
        case 1: score -= 1.2
        case 2: score -= 0.2
        case 3, 4: score += 1.6
        default: score += 0.4
        }

        // 与友军呼应 / 避免贴对方厚势
        var friendly = 0, hostile = 0
        for d in GoGame.dirs {
            let nx = x + d.0, ny = y + d.1
            guard inBounds(nx, ny, size) else { continue }
            if work[ny][nx] == color { friendly += 1 }
            else if work[ny][nx] == enemy { hostile += 1 }
        }
        score += Double(friendly) * 1.1 - Double(hostile) * 1.6

        // 开局开阔处加分
        if edge >= 2 && edge <= 6 {
            var nearby = 0
            for dy in -2...2 {
                for dx in -2...2 {
                    let nx = x + dx, ny = y + dy
                    if inBounds(nx, ny, size), board[ny][nx] != .empty { nearby += 1 }
                }
            }
            if nearby <= 2 { score += 2.4 }
        }

        return Evaluation(score: score, captured: captured, ownLiberties: ownLibs)
    }

    private static func liberties(_ board: [[GoColor]], size: Int, x: Int, y: Int,
                                  seen: inout Set<Int>, group: inout [GoPoint]?) -> Int {
        let color = board[y][x]
        guard color != .empty else { return 0 }
        var libs = 0
        var queue = [GoPoint(x: x, y: y)]
        seen.insert(y * size + x)
        if group != nil { group!.append(GoPoint(x: x, y: y)) }
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            for d in GoGame.dirs {
                let nx = p.x + d.0, ny = p.y + d.1
                guard inBounds(nx, ny, size) else { continue }
                if board[ny][nx] == .empty {
                    libs += 1
                } else if board[ny][nx] == color {
                    let key = ny * size + nx
                    if !seen.contains(key) {
                        seen.insert(key)
                        queue.append(GoPoint(x: nx, y: ny))
                        if group != nil { group!.append(GoPoint(x: nx, y: ny)) }
                    }
                }
            }
        }
        return libs
    }

    private static func inBounds(_ x: Int, _ y: Int, _ size: Int) -> Bool {
        x >= 0 && x < size && y >= 0 && y < size
    }

    /// 真眼判定: 四正邻与对角多为己方
    private static func isTrueEye(board: [[GoColor]], size: Int, x: Int, y: Int, color: GoColor) -> Bool {
        var own = 0, offBoard = 0
        for d in GoGame.dirs {
            let nx = x + d.0, ny = y + d.1
            if !inBounds(nx, ny, size) { offBoard += 1 }
            else if board[ny][nx] == color { own += 1 }
            else { return false }
        }
        if offBoard > 0 && own < 3 { return false }
        if offBoard == 0 && own < 4 { return false }
        var diagOwn = 0, diagTotal = 0
        for d in [(1, 1), (1, -1), (-1, 1), (-1, -1)] {
            let nx = x + d.0, ny = y + d.1
            if !inBounds(nx, ny, size) { continue }
            diagTotal += 1
            if board[ny][nx] == color { diagOwn += 1 }
            else if board[ny][nx] == color.opposite { return false }
        }
        return diagTotal == 0 || diagOwn >= diagTotal - 1
    }

    /// 空盘/近空盘的落点: 优先星位与 3-4 线
    private static func openingPoint(size: Int, board: [[GoColor]]) -> GoPoint? {
        var points: [GoPoint] = []
        if size >= 13 {
            let star = size >= 19 ? 3 : 3
            for (px, py) in [(star, star), (size - 1 - star, star),
                             (star, size - 1 - star), (size - 1 - star, size - 1 - star)] {
                if board[py][px] == .empty { points.append(GoPoint(x: px, y: py)) }
            }
        }
        if points.isEmpty {
            let low = size >= 13 ? 3 : 2
            let high = size - 1 - low
            if low <= high {
                for y in low...high {
                    for x in low...high where board[y][x] == .empty {
                        points.append(GoPoint(x: x, y: y))
                    }
                }
            }
        }
        return points.randomElement()
    }
}
