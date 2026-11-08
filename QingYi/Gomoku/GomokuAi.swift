import Foundation

/// 移植自 Android `com.sijia.go.GomokuAi`
/// 源文件：app/src/main/java/com/sijia/go/GomokuAi.java（只读参考，未做任何修改）
///
/// 方法一一对应：
///   levelName(level:)          ← levelName
///   think(game:level:)         ← GomokuActivity 里「copyBoard + choose + MoveFilter」的调用方式
///   choose(board:size:me:...)  ← choose(int[][] b, int me, int level, MoveFilter filter)
///   scorePoint                 ← scorePoint
///   contiguousScore            ← contiguousScore
///   windowScore                ← windowScore
///   candidates                 ← candidates(..., dist = 2)
///   countWinMoves              ← countWinMoves
///   openFourMove / openFourThrough / runThrough / isWinMove
///   findEmpty / countStones / in
///
/// 搜索深度、候选数、评估权重、分支阈值全部与 Java 相同，未做任何优化。
/// 纯计算，无 UI 依赖，可直接放到后台线程（先取好棋盘快照再调用）。
final class GomokuAi {
    static let maxLevel = 5

    /// 落点过滤（禁手模式下排除黑棋禁手点）。
    typealias MoveFilter = (Int, Int) -> Bool

    private static let dirs: [(Int, Int)] = [(1, 0), (0, 1), (1, 1), (1, -1)]

    private init() {}

    static func levelName(_ level: Int) -> String {
        switch max(1, min(maxLevel, level)) {
        case 1: return "入门"
        case 2: return "初级"
        case 3: return "中级"
        case 4: return "高级"
        default: return "大师"
        }
    }

    /// 同步入口：直接对当前棋局为行棋方算一手，返回 (x, y)；棋盘已满返回 nil。
    /// 内部先复制棋盘/颜色/禁手开关，之后只读副本，可在后台线程调用。
    static func think(game: GomokuGame, level: Int) -> (x: Int, y: Int)? {
        let snapshot = game.copyBoard()
        let n = game.size
        let color = game.turn
        let filter: MoveFilter? = (game.isRenju && color == GomokuGame.black)
            ? { (x: Int, y: Int) -> Bool in
                !GomokuGame.isForbiddenPoint(snapshot, size: n, x: x, y: y)
            }
            : nil
        return choose(board: snapshot, size: n, me: color, level: level, filter: filter)
    }

    /// 返回 (x, y)；棋盘已满时返回 nil。
    static func choose(board: [Int], size: Int, me: Int, level: Int) -> (x: Int, y: Int)? {
        choose(board: board, size: size, me: me, level: level, filter: nil)
    }

    /// 带落点过滤的版本：filter 返回 false 的点不会作为己方落点（用于禁手）。
    static func choose(board source: [Int], size: Int, me: Int, level: Int,
                       filter: MoveFilter?) -> (x: Int, y: Int)? {
        let n = size
        if n <= 0 { return nil }
        guard source.count >= n * n else { return nil }
        let center = n / 2
        if countStones(source, n) == 0 { return (center, center) }
        let opp = 3 - me
        var b = source

        var cand = candidates(b, n, 2)
        if let filter = filter {
            cand = cand.filter { filter($0.x, $0.y) }
        }
        if cand.isEmpty { return findEmpty(b, n) }

        // 1. 自己能成五：直接赢
        for c in cand {
            if isWinMove(&b, n, c.x, c.y, me) { return (c.x, c.y) }
        }
        // 2. 对手下一步能成五：必须堵
        for c in cand {
            if isWinMove(&b, n, c.x, c.y, opp) { return (c.x, c.y) }
        }

        var scored: [ScoredMove] = []
        scored.reserveCapacity(cand.count)
        for (i, c) in cand.enumerated() {
            let attack = scorePoint(b, n, c.x, c.y, me)
            let defend = scorePoint(b, n, c.x, c.y, opp)
            scored.append(ScoredMove(x: c.x, y: c.y,
                                     attack: attack, defend: defend,
                                     total: attack + defend * 9 / 10,
                                     order: i))
        }
        // Java 的 List.sort 是稳定排序（TimSort），这里用 order 复刻同等行为
        scored.sort { lhs, rhs in
            if lhs.total == rhs.total { return lhs.order < rhs.order }
            return lhs.total > rhs.total
        }

        if level <= 1 {
            // 入门：在最优的三个点里随机，避免每局一模一样
            let k = min(3, scored.count)
            let pick = scored[Int.random(in: 0..<k)]
            return (pick.x, pick.y)
        }

        if level == 2 {
            // 初级：贪心，防守权重偏低（会漏防活三，弱于中级）
            var best = scored[0]
            var bestV = Int.min
            for m in scored {
                let v = m.attack + m.defend * 4 / 10
                if v > bestV {
                    bestV = v
                    best = m
                }
            }
            return (best.x, best.y)
        }

        // 3. 自己下一手能成活四：抢先做活四（对方只能堵一头，随后成五）
        for c in cand {
            if openFourMove(&b, n, c.x, c.y, me) { return (c.x, c.y) }
        }

        // 4. 对手下一手能成活四（即我方面临活三）：必须挡在关键点
        var keyBlocks: [(x: Int, y: Int)] = []
        for c in cand {
            if openFourMove(&b, n, c.x, c.y, opp) { keyBlocks.append((c.x, c.y)) }
        }
        if !keyBlocks.isEmpty {
            var bestBlock: (x: Int, y: Int)?
            var bestBlockValue = Int.min
            for c in keyBlocks {
                let v = scorePoint(b, n, c.x, c.y, me) + scorePoint(b, n, c.x, c.y, opp)
                if v > bestBlockValue {
                    bestBlockValue = v
                    bestBlock = (c.x, c.y)
                }
            }
            if let bestBlock = bestBlock { return bestBlock }
        }

        // 中级：贪心（防守权重 0.9）+ 双威胁（双活三 / 四三 / 双四）
        if level == 3 {
            let top = min(10, scored.count)
            for i in 0..<top {
                let m = scored[i]
                b[m.y * n + m.x] = me
                let fork = countWinMoves(&b, n, me, 2) >= 2
                b[m.y * n + m.x] = GomokuGame.empty
                if fork { return (m.x, m.y) }
            }
            return (scored[0].x, scored[0].y)
        }

        // 高级搜索前 6 个候选，大师搜索前 14 个（更不易漏掉反击手段）
        let topK = min(level >= 5 ? 14 : 6, scored.count)
        var bestValue = Int.min
        var best: (x: Int, y: Int)?
        for i in 0..<topK {
            let m = scored[i]
            b[m.y * n + m.x] = me
            let value: Int

            // 双威胁（双活三 / 四三 / 双四）：对手无法同时防住，视为必胜
            let myThreats = countWinMoves(&b, n, me, 2)
            if level >= 5 && myThreats >= 2 {
                value = 900_000_000 + m.total
            } else {
                let oc = candidates(b, n, 2)
                var oppBest = 0
                var oppWin = false
                var oppMove: (x: Int, y: Int)?
                for o in oc {
                    if isWinMove(&b, n, o.x, o.y, opp) {
                        oppWin = true
                        break
                    }
                    let s = scorePoint(b, n, o.x, o.y, opp)
                    if s > oppBest {
                        oppBest = s
                        oppMove = (o.x, o.y)
                    }
                }
                if oppWin {
                    // 这一手给了对手成五机会，基本不能走
                    value = Int.min / 4 + m.total
                } else {
                    var v = m.total - oppBest * 9 / 10
                    // 单一威胁（做出一个四）：大师更愿意抢先手
                    if myThreats == 1 {
                        v += level >= 5 ? 4_000_000 : 150_000
                    }
                    // 大师：对手最佳应手若直接形成活四（四三 / 双四同理），挡不住
                    if level >= 5, let om = oppMove, openFourMove(&b, n, om.x, om.y, opp) {
                        v = Int.min / 8 + m.total
                    }
                    value = v
                }
            }
            b[m.y * n + m.x] = GomokuGame.empty
            if value > bestValue {
                bestValue = value
                best = (m.x, m.y)
            }
        }
        return best ?? (scored[0].x, scored[0].y)
    }

    // ---------------- 棋型评分（权重与 Java 逐项一致） ----------------

    /// 假设在 (x,y) 落 color 子后的局部价值。调用前该点应为空。
    private static func scorePoint(_ b: [Int], _ n: Int, _ x: Int, _ y: Int, _ color: Int) -> Int {
        let opp = 3 - color
        var total = 0
        for d in dirs {
            let dx = d.0
            let dy = d.1
            var count = 1
            var open = 0

            var cx = x + dx
            var cy = y + dy
            while inside(n, cx, cy) && b[cy * n + cx] == color {
                count += 1
                cx += dx
                cy += dy
            }
            if inside(n, cx, cy) && b[cy * n + cx] == GomokuGame.empty { open += 1 }

            cx = x - dx
            cy = y - dy
            while inside(n, cx, cy) && b[cy * n + cx] == color {
                count += 1
                cx -= dx
                cy -= dy
            }
            if inside(n, cx, cy) && b[cy * n + cx] == GomokuGame.empty { open += 1 }

            total += contiguousScore(count, open)

            // 五格窗口：把断点棋型（如 11011）也计入
            for s in -4...0 {
                var ok = true
                var cnt = 0
                for k in 0..<5 {
                    let ox = s + k
                    let nx = x + dx * ox
                    let ny = y + dy * ox
                    if !inside(n, nx, ny) {
                        ok = false
                        break
                    }
                    let v = ox == 0 ? color : b[ny * n + nx]
                    if v == opp {
                        ok = false
                        break
                    }
                    if v == color { cnt += 1 }
                }
                if ok { total += windowScore(cnt) }
            }
        }
        return total
    }

    private static func contiguousScore(_ count: Int, _ open: Int) -> Int {
        if count >= 5 { return 50_000_000 }
        if count == 4 { return open == 2 ? 5_000_000 : (open == 1 ? 400_000 : 0) }
        if count == 3 { return open == 2 ? 300_000 : (open == 1 ? 20_000 : 0) }
        if count == 2 { return open == 2 ? 8_000 : (open == 1 ? 1_000 : 0) }
        return open == 2 ? 200 : 0
    }

    private static func windowScore(_ count: Int) -> Int {
        switch count {
        case 5: return 5_000_000
        case 4: return 50_000
        case 3: return 4_000
        case 2: return 400
        default: return 20
        }
    }

    // ---------------- 搜索辅助 ----------------

    private static func countWinMoves(_ b: inout [Int], _ n: Int, _ color: Int, _ limit: Int) -> Int {
        var c = 0
        for p in candidates(b, n, 2) {
            if isWinMove(&b, n, p.x, p.y, color) {
                c += 1
                if c >= limit { break }
            }
        }
        return c
    }

    /// 该点落 color 后是否在某个方向形成活四（连续 4 子且两端皆空）。
    private static func openFourMove(_ b: inout [Int], _ n: Int, _ x: Int, _ y: Int, _ color: Int) -> Bool {
        if b[y * n + x] != GomokuGame.empty { return false }
        b[y * n + x] = color
        var open = false
        for d in dirs {
            if openFourThrough(b, n, x, y, d.0, d.1, color) {
                open = true
                break
            }
        }
        b[y * n + x] = GomokuGame.empty
        return open
    }

    private static func openFourThrough(_ b: [Int], _ n: Int, _ x: Int, _ y: Int,
                                        _ dx: Int, _ dy: Int, _ color: Int) -> Bool {
        if runThrough(b, n, x, y, dx, dy, color) != 4 { return false }
        var x1 = x, y1 = y, x2 = x, y2 = y
        while inside(n, x1 - dx, y1 - dy) && b[(y1 - dy) * n + (x1 - dx)] == color {
            x1 -= dx
            y1 -= dy
        }
        while inside(n, x2 + dx, y2 + dy) && b[(y2 + dy) * n + (x2 + dx)] == color {
            x2 += dx
            y2 += dy
        }
        return inside(n, x1 - dx, y1 - dy) && b[(y1 - dy) * n + (x1 - dx)] == GomokuGame.empty
            && inside(n, x2 + dx, y2 + dy) && b[(y2 + dy) * n + (x2 + dx)] == GomokuGame.empty
    }

    private static func runThrough(_ b: [Int], _ n: Int, _ x: Int, _ y: Int,
                                   _ dx: Int, _ dy: Int, _ color: Int) -> Int {
        var cnt = 1
        var cx = x + dx
        var cy = y + dy
        while inside(n, cx, cy) && b[cy * n + cx] == color {
            cnt += 1
            cx += dx
            cy += dy
        }
        cx = x - dx
        cy = y - dy
        while inside(n, cx, cy) && b[cy * n + cx] == color {
            cnt += 1
            cx -= dx
            cy -= dy
        }
        return cnt
    }

    private static func isWinMove(_ b: inout [Int], _ n: Int, _ x: Int, _ y: Int, _ color: Int) -> Bool {
        if !inside(n, x, y) || b[y * n + x] != GomokuGame.empty { return false }
        b[y * n + x] = color
        var win = false
        for d in dirs {
            var cnt = 1
            var cx = x + d.0
            var cy = y + d.1
            while inside(n, cx, cy) && b[cy * n + cx] == color {
                cnt += 1
                cx += d.0
                cy += d.1
            }
            cx = x - d.0
            cy = y - d.1
            while inside(n, cx, cy) && b[cy * n + cx] == color {
                cnt += 1
                cx -= d.0
                cy -= d.1
            }
            if cnt >= 5 {
                win = true
                break
            }
        }
        b[y * n + x] = GomokuGame.empty
        return win
    }

    /// 已有棋子附近 dist 格内的空点；棋盘为空时返回全部空点。
    private static func candidates(_ b: [Int], _ n: Int, _ dist: Int) -> [(x: Int, y: Int)] {
        var mark = Array(repeating: false, count: n * n)
        var any = false
        for y in 0..<n {
            for x in 0..<n {
                if b[y * n + x] == GomokuGame.empty { continue }
                any = true
                for dy in -dist...dist {
                    for dx in -dist...dist {
                        let nx = x + dx
                        let ny = y + dy
                        if inside(n, nx, ny) && b[ny * n + nx] == GomokuGame.empty {
                            mark[ny * n + nx] = true
                        }
                    }
                }
            }
        }
        var out: [(x: Int, y: Int)] = []
        if !any {
            for y in 0..<n {
                for x in 0..<n { out.append((x, y)) }
            }
            return out
        }
        for y in 0..<n {
            for x in 0..<n {
                if mark[y * n + x] { out.append((x, y)) }
            }
        }
        return out
    }

    private static func findEmpty(_ b: [Int], _ n: Int) -> (x: Int, y: Int)? {
        for y in 0..<n {
            for x in 0..<n {
                if b[y * n + x] == GomokuGame.empty { return (x, y) }
            }
        }
        return nil
    }

    private static func countStones(_ b: [Int], _ n: Int) -> Int {
        var c = 0
        for i in 0..<(n * n) where b[i] != GomokuGame.empty { c += 1 }
        return c
    }

    private static func inside(_ n: Int, _ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < n && y < n
    }

    private struct ScoredMove {
        let x: Int
        let y: Int
        let attack: Int
        let defend: Int
        let total: Int
        let order: Int
    }
}
