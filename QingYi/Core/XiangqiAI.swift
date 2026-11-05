import Foundation

/// 内置象棋 AI (10 档): alpha-beta 迭代加深 + 吃子排序
enum XiangqiAI {

    struct ScoredMove {
        var move: XiangqiGame.Move
        var score: Int
    }

    static func bestMove(in game: XiangqiGame, level rawLevel: Int) -> XiangqiGame.Move? {
        let level = max(1, min(10, rawLevel))
        let root = game.copyForSearch()
        let moves = root.legalMoves()
        guard !moves.isEmpty else { return nil }
        // 单一合法着法直接返回
        if moves.count == 1 { return moves[0] }

        let maxDepth: Int
        switch level {
        case 1, 2: maxDepth = 1
        case 3, 4: maxDepth = 2
        case 5, 6: maxDepth = 3
        case 7, 8: maxDepth = 4
        default: maxDepth = 5
        }
        // 低档思考时间短, 高档给足
        let timeLimit: TimeInterval = [0.05, 0.08, 0.15, 0.25, 0.4, 0.6, 0.9, 1.2, 1.6, 2.0][level - 1]
        let deadline = Date().addingTimeInterval(timeLimit)

        var ordered = orderMoves(moves, in: root)
        var best = ordered[0]
        var bestScore = -Int.max / 2
        var results: [ScoredMove] = []

        for depth in 1...maxDepth {
            var iterationBest: XiangqiGame.Move? = nil
            var iterationScore = -Int.max / 2
            var iterationResults: [ScoredMove] = []
            var alpha = -Int.max / 2
            let beta = Int.max / 2

            for (idx, candidate) in ordered.enumerated() {
                if Date() > deadline && depth > 1 { break }
                var move = candidate
                move = root.makeSearchMove(move)
                let score = -search(root, depth: depth - 1, alpha: -beta, beta: -alpha,
                                    ply: 1, deadline: deadline, nodes: &searchNodes)
                root.unmakeSearchMove(move)
                iterationResults.append(ScoredMove(move: candidate, score: score))
                if score > iterationScore {
                    iterationScore = score
                    iterationBest = candidate
                }
                if score > alpha { alpha = score }
                _ = idx
            }

            if let ib = iterationBest {
                best = ib
                bestScore = iterationScore
                results = iterationResults
                // 下一轮按本轮得分排序, 提升剪枝效率
                let sorted = iterationResults.sorted { $0.score > $1.score }
                ordered = sorted.map { $0.move }
            }
            if abs(bestScore) > 20000 { break }
        }

        // 低档棋力: 从前几名里随机, 制造失误
        if level <= 4, results.count > 1 {
            let sorted = results.sorted { $0.score > $1.score }
            let pool: Int
            switch level {
            case 1: pool = min(sorted.count, 4)
            case 2: pool = min(sorted.count, 3)
            case 3: pool = min(sorted.count, 2)
            default: pool = 1
            }
            if pool > 1, let pick = sorted.prefix(pool).randomElement() {
                return pick.move
            }
        }
        _ = bestScore
        return best
    }

    private static var searchNodes = 0

    // MARK: - 搜索

    private static func search(_ game: XiangqiGame, depth: Int, alpha: Int, beta: Int,
                               ply: Int, deadline: Date, nodes: inout Int) -> Int {
        nodes += 1
        if nodes % 4096 == 0 && Date() > deadline { return evaluate(game) }

        if depth <= 0 {
            return quiescence(game, alpha: alpha, beta: beta, depth: 2, deadline: deadline, nodes: &nodes)
        }

        let moves = game.legalMoves()
        if moves.isEmpty {
            // 被将死或困毙
            return -30000 + ply
        }

        var alphaV = alpha
        for m in orderMoves(moves, in: game) {
            let applied = game.makeSearchMove(m)
            let score = -search(game, depth: depth - 1, alpha: -beta, beta: -alphaV,
                                ply: ply + 1, deadline: deadline, nodes: &nodes)
            game.unmakeSearchMove(applied)
            if score >= beta { return beta }
            if score > alphaV { alphaV = score }
        }
        return alphaV
    }

    /// 吃子延伸, 减少明显漏算
    private static func quiescence(_ game: XiangqiGame, alpha: Int, beta: Int,
                                   depth: Int, deadline: Date, nodes: inout Int) -> Int {
        nodes += 1
        if nodes % 4096 == 0 && Date() > deadline { return evaluate(game) }
        var stand = evaluate(game)
        if depth <= 0 { return stand }
        if stand >= beta { return beta }
        var alphaV = max(alpha, stand)

        let captures = game.legalMoves().filter { $0.captured != nil }
        if captures.isEmpty { return stand }

        for m in orderMoves(captures, in: game) {
            let applied = game.makeSearchMove(m)
            // 对方被将死则直接返回
            let score = -quiescence(game, alpha: -beta, beta: -alphaV,
                                    depth: depth - 1, deadline: deadline, nodes: &nodes)
            game.unmakeSearchMove(applied)
            if score >= beta { return beta }
            if score > alphaV { alphaV = score }
            stand = alphaV
        }
        return stand
    }

    /// 着法排序: 吃子优先(MVV-LVA), 其次将军
    private static func orderMoves(_ moves: [XiangqiGame.Move], in game: XiangqiGame) -> [XiangqiGame.Move] {
        moves.sorted { a, b in
            moveOrderScore(a) > moveOrderScore(b)
        }
    }

    private static func moveOrderScore(_ m: XiangqiGame.Move) -> Int {
        guard let victim = m.captured else { return 0 }
        return 4000 + pieceValue(victim) - (m.piece.map { pieceValue($0) } ?? 0) / 10
    }

    // MARK: - 评估

    private static func evaluate(_ game: XiangqiGame) -> Int {
        // 相对当前行棋方
        var score = 0
        for y in 0..<XiangqiGame.rows {
            for x in 0..<XiangqiGame.cols {
                guard let p = game.piece(at: x, y) else { continue }
                let v = pieceValue(p) + positionValue(p, x: x, y: y)
                score += p.color == game.turn ? v : -v
            }
        }
        return score
    }

    private static func pieceValue(_ p: XiangqiGame.Piece) -> Int {
        switch p.kind {
        case .king: return 6000
        case .rook: return 600
        case .cannon: return 300
        case .horse: return 300
        case .advisor: return 120
        case .elephant: return 120
        case .pawn: return 70
        }
    }

    private static func positionValue(_ p: XiangqiGame.Piece, x: Int, y: Int) -> Int {
        // 以红方视角定义, 黑方上下镜像
        let ry = p.color == .red ? y : XiangqiGame.rows - 1 - y
        let center = 4 - abs(x - 4)
        switch p.kind {
        case .pawn:
            var v = 0
            if ry <= 4 { v += 60 }          // 过河兵
            v += (9 - ry) * 6               // 越靠前越好
            v += center * 3
            return v
        case .horse:
            return center * 8 + (ry <= 4 ? 8 : 0)
        case .cannon:
            return center * 6
        case .rook:
            return center * 4
        case .advisor, .elephant:
            return 0
        case .king:
            // 老将不宜离中线太远
            return -abs(x - 4) * 4
        }
    }
}
