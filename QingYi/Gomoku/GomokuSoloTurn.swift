import Foundation

/// 单机人机回合推进的纯逻辑（不依赖 SwiftUI / Combine，可在命令行直接跑用例）。
///
/// 抽出来的原因：UI 模型里漏掉「玩家落子后叫 AI」不会编译报错，只会静默不动，
/// 这类问题只能靠可独立执行的用例兜住。
enum GomokuSoloTurn {
    /// 玩家落子 / 悔棋 / 读谱之后，是否该由 AI 接手。
    /// 等价于 Android `GomokuActivity.afterMove()` 里的
    /// `if (isAiMode() && game.turn() != playerColor) aiMove();`
    static func needsAI(isAIMode: Bool, playerColor: Int, turn: Int,
                        isOver: Bool, isFull: Bool) -> Bool {
        guard isAIMode, !isOver, !isFull else { return false }
        return turn != playerColor
    }

    /// AI 选点：禁手模式下排除黑棋禁手点；与 Android `aiMove()` 的 filter 构造完全一致。
    /// 纯函数，可在后台线程调用（调用方先取棋盘快照）。
    static func chooseMove(board: [Int], size: Int, me: Int, level: Int,
                           renju: Bool) -> (x: Int, y: Int)? {
        let filter: GomokuAi.MoveFilter? = (renju && me == GomokuGame.black)
            ? { (x: Int, y: Int) -> Bool in
                !GomokuGame.isForbiddenPoint(board, size: size, x: x, y: y)
            }
            : nil
        return GomokuAi.choose(board: board, size: size, me: me, level: level, filter: filter)
    }
}
