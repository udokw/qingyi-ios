//
//  BanqiAi.swift
//  清弈
//
//  移植自 Android：app/src/main/java/com/sijia/go/banqi/BanqiAI.java
//  暗棋启发式 AI。同步入口，不依赖 UI，可在后台线程调用。
//
//  暗棋是不完全信息博弈，本 AI 不做完全信息搜索：
//  - 走子/吃子：模拟一步后用局面评估函数打分，并（中高段位）额外计算对手最佳吃子反击；
//  - 翻子：使用“剩余暗子池”的期望值，不读取任何暗子的具体身份；
//  - 评估包含子力、机动性、互相威胁、將的安全、行动节奏；
//  - 接近无进展和棋阈值时提高翻子意愿，避免被动判和。
//
//  段位 1~10：1 纯随机；2~3 大噪声；4~5 中噪声；6~8 小噪声 + 反击检查；
//  9~10 取评估最优。
//

import Foundation

final class BanqiAi {

    /// 下标即段位。
    private static let noise: [Double] = [0, 0, 4.5, 3.0, 1.8, 1.0, 0.55, 0.28, 0.12, 0.04, 0]
    /// 下标即段位；取排序后前 ceil(n * ratio) 个里随机。
    private static let topRatio: [Double] = [1, 1, 0.70, 0.55, 0.45, 0.35, 0.25, 0.15, 0.07, 0.03, 0.01]

    private init() {}

    // MARK: - 入口

    /// 同步选一手；无合法着法或棋局已结束返回 nil。
    static func choose(in game: BanqiGame, level: Int) -> BanqiGame.Move? {
        var rng = SystemRandomNumberGenerator()
        return choose(in: game, level: level, using: &rng)
    }

    /// 可注入随机源，便于自测复现。
    static func choose<R: RandomNumberGenerator>(in game: BanqiGame,
                                                 level: Int,
                                                 using rng: inout R) -> BanqiGame.Move? {
        if game.isOver {
            return nil
        }
        let lv = max(1, min(10, level))
        let actions = game.legalActions()
        if actions.isEmpty {
            return nil
        }
        if lv == 1 {
            return actions[Int.random(in: 0..<actions.count, using: &rng)]
        }

        let seat = game.turnSeat
        var scored: [Scored] = []
        scored.reserveCapacity(actions.count)
        for m in actions {
            var score: Double
            if m.flip {
                score = flipScore(game: game, move: m, seat: seat)
            } else {
                score = moveScore(game: game, move: m, seat: seat, level: lv)
            }
            score += nextDouble(&rng) * BanqiAi.noise[lv]
            scored.append(Scored(move: m, score: score))
        }

        // Java Collections.sort 是稳定排序：同分保持生成顺序。
        let ordered = scored.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.score == rhs.element.score {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.score > rhs.element.score
            }
            .map { $0.element }

        let top = max(1, Int(ceil(Double(ordered.count) * BanqiAi.topRatio[lv])))
        return ordered[Int.random(in: 0..<top, using: &rng)].move
    }

    // MARK: - 翻子期望值

    private static func flipScore(game: BanqiGame, move: BanqiGame.Move, seat: Int) -> Double {
        var value = expectedFlipMaterial(game: game, seat: seat)
        // 翻子本身推进局面、打断无进展计数
        value += 0.20
        value += Double(max(0, game.idlePlies - 12)) * 0.15
        value += 0.03 * centerValue(x: move.x, y: move.y)
        value -= flipRisk(game: game, x: move.x, y: move.y, seat: seat)
        return value
    }

    /// 翻一枚暗子的期望子力收益（从 AI 视角）。
    /// 只使用剩余暗子池的聚合计数，不使用任何具体格子的暗子身份。
    private static func expectedFlipMaterial(game: BanqiGame, seat: Int) -> Double {
        guard let pool = game.unseenPool() else {
            return 0
        }
        var total = 0
        var redSum = 0.0
        var blackSum = 0.0
        for p in 1..<pool.count {
            let count = pool[p]
            if count <= 0 {
                continue
            }
            total += count
            let v = pieceValue(BanqiGame.typeOf(p))
            if BanqiGame.colorOf(p) == BanqiGame.red {
                redSum += v * Double(count)
            } else {
                blackSum += v * Double(count)
            }
        }
        if total == 0 {
            return 0
        }
        let myColor = game.colorOfSeat(seat)
        if myColor == 0 {
            // 首翻：翻出即归自己
            return (redSum + blackSum) / Double(total)
        }
        let mine = myColor == BanqiGame.red ? redSum : blackSum
        let theirs = myColor == BanqiGame.red ? blackSum : redSum
        return (mine - theirs) / Double(total)
    }

    /// 翻出的明子若紧贴敌方明子，容易被立即吃掉，做位置风险折扣。
    private static func flipRisk(game: BanqiGame, x: Int, y: Int, seat: Int) -> Double {
        let myColor = game.colorOfSeat(seat)
        if myColor == 0 {
            return 0
        }
        let enemy = 3 - myColor
        var risk = 0.0
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for d in dirs {
            let nx = x + d.0
            let ny = y + d.1
            if !game.isFaceUp(nx, ny) {
                continue
            }
            let p = game.pieceCodeAt(nx, ny)
            if BanqiGame.colorOf(p) == enemy {
                risk += 0.10 + pieceValue(BanqiGame.typeOf(p)) * 0.015
            }
        }
        return risk
    }

    // MARK: - 走子评分

    private static func moveScore(game: BanqiGame, move: BanqiGame.Move, seat: Int, level: Int) -> Double {
        let sim = game.copyForSearch()
        if !sim.play(move) {
            return -10000
        }
        var score = evaluate(game: sim, seat: seat)
        if level >= 6 && !sim.isOver {
            score += opponentBestCaptureDelta(game: sim, seat: seat) * 0.85
        }
        return score
    }

    /// 对手最佳吃子带来的分差（≤0），用于避免白送子。
    private static func opponentBestCaptureDelta(game: BanqiGame, seat: Int) -> Double {
        let base = evaluate(game: game, seat: seat)
        var worst = 0.0
        for m in game.legalActions() {
            if m.flip || m.captured == BanqiGame.empty {
                continue
            }
            let sim = game.copyForSearch()
            if sim.play(m) {
                worst = min(worst, evaluate(game: sim, seat: seat) - base)
            }
        }
        return worst
    }

    // MARK: - 局面评估

    private static func evaluate(game: BanqiGame, seat: Int) -> Double {
        if game.isOver {
            if game.result == BanqiGame.resultDraw {
                return 0
            }
            let myColor = game.colorOfSeat(seat)
            if myColor == 0 {
                return 0
            }
            return game.result == myColor ? 1000 : -1000
        }
        let myColor = game.colorOfSeat(seat)
        if myColor == 0 {
            return 0
        }
        let enemyColor = 3 - myColor
        var score = 0.0
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                if !game.isFaceUp(x, y) {
                    continue
                }
                let p = game.pieceCodeAt(x, y)
                let v = pieceValue(BanqiGame.typeOf(p)) + 0.10 * centerValue(x: x, y: y)
                score += BanqiGame.colorOf(p) == myColor ? v : -v
            }
        }
        let myMoves = game.movesForColor(myColor).count
        let enemyMoves = game.movesForColor(enemyColor).count
        score += 0.16 * Double(myMoves - enemyMoves)
        score += attackScore(game: game, color: myColor) + attackScore(game: game, color: enemyColor) * -1
        // 行动节奏：轮到己方略加分
        score += game.turnSeat == seat ? 0.35 : -0.35
        return score
    }

    /// 某方所有吃子威胁的加权和；卒威胁將额外加权。
    private static func attackScore(game: BanqiGame, color: Int) -> Double {
        var score = 0.0
        for m in game.movesForColor(color) {
            if m.captured == BanqiGame.empty {
                continue
            }
            let targetType = BanqiGame.typeOf(m.captured)
            var gain = 0.30 * pieceValue(targetType)
            if targetType == BanqiGame.king && BanqiGame.typeOf(m.piece) == BanqiGame.pawn {
                gain += 2.5
            }
            score += gain
        }
        return score
    }

    private static func centerValue(x: Int, y: Int) -> Double {
        let cx = 1.0 - abs(Double(x) - 3.5) / 3.5
        let cy = 1.0 - abs(Double(y) - 1.5) / 1.5
        return 0.10 * cx + 0.05 * cy
    }

    private static func pieceValue(_ type: Int) -> Double {
        if type == BanqiGame.king { return 8.5 }
        if type == BanqiGame.advisor { return 6.2 }
        if type == BanqiGame.elephant { return 5.8 }
        if type == BanqiGame.rook { return 5.0 }
        if type == BanqiGame.horse { return 4.2 }
        if type == BanqiGame.cannon { return 4.6 }
        if type == BanqiGame.pawn { return 3.4 }
        return 0
    }

    // MARK: - 工具

    /// [0, 1) 均匀分布，等价于 Java Random.nextDouble()。
    private static func nextDouble<R: RandomNumberGenerator>(_ rng: inout R) -> Double {
        Double(rng.next() >> 11) * (1.0 / 9007199254740992.0)
    }

    private struct Scored {
        let move: BanqiGame.Move
        let score: Double
    }
}
