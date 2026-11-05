import Foundation
import Combine

/// 象棋对弈 / 本地双人 / PGN 复盘
final class XiangqiGameModel: ObservableObject {
    let setup: XiangqiSetup
    private(set) var game: XiangqiGame
    let mode: PlayMode
    let playerColor: XiangqiGame.Color
    let level: Int
    let showHints: Bool

    @Published var selection: GoPoint?
    @Published var hints: [GoPoint] = []
    @Published var thinking = false
    @Published var alert: GameAlert?
    @Published var resultText: String?
    @Published var transientStatus: String?
    @Published var reviewIndex = 0
    @Published var reviewTotal = 0
    @Published var comment: String?

    private var lastMoveText = ""
    private var transientToken = 0
    private var generation = 0
    private var reviewMoves: [String] = []

    init(setup: XiangqiSetup) {
        self.setup = setup
        self.game = XiangqiGame()
        self.mode = setup.mode
        self.playerColor = setup.playerColor
        self.level = setup.level
        self.showHints = setup.hints

        if setup.mode == .review, let url = setup.recordURL {
            loadReview(url)
        } else if setup.mode == .ai, game.turn != playerColor {
            DispatchQueue.main.async { [weak self] in
                self?.startAI()
            }
        }
    }

    // MARK: - 状态

    var leftTitle: String {
        switch mode {
        case .ai: return playerColor == .red ? "我执红" : "我执黑"
        case .local: return "本地双人"
        case .review: return "棋谱复盘"
        }
    }

    var subTitle: String {
        switch mode {
        case .ai: return "等级 \(level) · 内置引擎"
        case .local: return "红黑轮流 · 同一设备"
        case .review: return "PGN 复盘 · 逐手回放"
        }
    }

    var statusText: String {
        if let transientStatus { return transientStatus }
        if let resultText { return resultText }
        if mode == .review { return "\(reviewIndex) / \(reviewTotal) 手" }
        if thinking { return "对方思考中…" }
        let side = game.turn == .red ? "红方" : "黑方"
        if lastMoveText.isEmpty { return "轮到 \(side) 行棋" }
        return "轮到 \(side) 行棋 · 上着 \(lastMoveText)"
    }

    var lastMove: XiangqiGame.Move? { game.lastMove }
    var isFinished: Bool { resultText != nil }
    var isReview: Bool { mode == .review }

    var lastMoveTexts: [String] {
        var out: [String] = []
        for m in game.history { out.append(game.notation(m)) }
        return out
    }

    // MARK: - 点按

    func tap(_ x: Int, _ y: Int) {
        guard mode != .review, !thinking, !isFinished else { return }
        if mode == .ai, game.turn != playerColor { return }

        let turn = game.turn
        let tapped = game.piece(at: x, y)

        // 未选中时直接点对方棋子: 若只有一枚己方子能吃, 直接吃
        if selection == nil, let p = tapped, p.color != turn {
            let caps = capturesTo(x, y, color: turn)
            if caps.count == 1 {
                _ = playMove(caps[0].from, caps[0].to)
                return
            }
            if caps.count > 1 {
                flash("有 \(caps.count) 枚棋子可吃，请先选中一枚")
                return
            }
        }

        if let from = selection {
            if let p = tapped, p.color == turn {
                select(x, y)
                return
            }
            let to = GoPoint(x: x, y: y)
            if playMove(from, to) { return }
            flash(game.illegalReason(from: from, to: to))
            clearSelection()
            refresh()
            return
        }

        if let p = tapped, p.color == turn {
            select(x, y)
        } else {
            flash("先选中己方棋子")
        }
    }

    func drag(from: GoPoint, to: GoPoint) {
        guard mode != .review, !thinking, !isFinished else { return }
        if mode == .ai, game.turn != playerColor { return }
        guard let p = game.piece(at: from.x, from.y), p.color == game.turn else {
            tap(to.x, to.y)
            return
        }
        if playMove(from, to) { return }
        select(from.x, from.y)
        flash(game.illegalReason(from: from, to: to))
    }

    private func select(_ x: Int, _ y: Int) {
        selection = GoPoint(x: x, y: y)
        hints = showHints ? game.legalMoves(from: GoPoint(x: x, y: y)).map { $0.to } : []
        refresh()
    }

    private func clearSelection() {
        selection = nil
        hints = []
    }

    /// 当前轮到一方所有能落到目标点的着法
    private func capturesTo(_ tx: Int, _ ty: Int, color: XiangqiGame.Color) -> [XiangqiGame.Move] {
        var out: [XiangqiGame.Move] = []
        for y in 0..<XiangqiGame.rows {
            for x in 0..<XiangqiGame.cols {
                guard let p = game.piece(at: x, y), p.color == color else { continue }
                for m in game.legalMoves(from: GoPoint(x: x, y: y)) where m.to.x == tx && m.to.y == ty {
                    out.append(m)
                }
            }
        }
        return out
    }

    @discardableResult
    private func playMove(_ from: GoPoint, _ to: GoPoint) -> Bool {
        guard game.play(from: from, to: to) else { return false }
        if let m = game.history.last {
            lastMoveText = game.notation(m)
        }
        clearSelection()
        SoundPlayer.shared.playMove()
        refresh()

        if game.isOver {
            finishGame()
            return true
        }
        if game.inCheck(game.turn) {
            SoundPlayer.shared.playCheck()
            flash("将军！")
        }
        if mode == .ai, game.turn != playerColor {
            startAI()
        }
        return true
    }

    // MARK: - AI

    private func startAI() {
        guard mode == .ai, !thinking, !isFinished else { return }
        thinking = true
        let snapshot = game.copyForSearch()
        let level = level
        let gen = generation

        DispatchQueue.global(qos: .userInitiated).async {
            let move = XiangqiAI.bestMove(in: snapshot, level: level)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.thinking = false
                guard let move, self.game.play(from: move.from, to: move.to) else {
                    self.refresh()
                    if !self.game.isOver { self.flash("对方无着可走") }
                    return
                }
                if let last = self.game.history.last {
                    self.lastMoveText = self.game.notation(last)
                }
                SoundPlayer.shared.playMove()
                self.refresh()
                if self.game.isOver {
                    self.finishGame()
                } else if self.game.inCheck(self.game.turn) {
                    SoundPlayer.shared.playCheck()
                    self.flash("将军！")
                } else {
                    self.flash("对方落子")
                }
            }
        }
    }

    // MARK: - 操作

    func undo() {
        guard !thinking, mode != .review, !isFinished else { return }
        if mode == .ai {
            if game.plies > 0 { _ = game.undo() }
            if game.plies > 0, game.turn != playerColor { _ = game.undo() }
        } else {
            _ = game.undo()
        }
        resultText = nil
        clearSelection()
        lastMoveText = game.history.last.map { game.notation($0) } ?? ""
        refresh()
        flash("已悔棋")
    }

    func resign() {
        guard !isFinished, mode != .review, !thinking else { return }
        let side = mode == .ai ? playerColor : game.turn
        alert = GameAlert(title: "确认认输",
                          message: "认输后本局结束。",
                          confirmTitle: "确认认输") { [weak self] in
            guard let self else { return }
            self.game.resign(side)
            self.finishGame()
            self.refresh()
        }
    }

    func agreeDraw() {
        guard !isFinished, mode != .review, !thinking else { return }
        alert = GameAlert(title: "提议和棋",
                          message: "双方同意后本局判和。",
                          confirmTitle: "同意和棋") { [weak self] in
            guard let self else { return }
            self.game.agreeDraw()
            self.finishGame()
            self.refresh()
        }
    }

    private func finishGame() {
        let reason = game.endReason.isEmpty ? "对局结束" : game.endReason
        resultText = reason
        generation += 1
        thinking = false
        clearSelection()
        alert = GameAlert(title: "对局结束", message: reason)
    }

    // MARK: - 复盘

    func reviewStep(_ delta: Int) {
        guard mode == .review else { return }
        let next = min(max(0, reviewIndex + delta), reviewTotal)
        guard next != reviewIndex else { return }
        rebuildReview(next)
    }

    private func loadReview(_ url: URL) {
        guard let loaded = try? XiangqiPgn.load(url) else {
            alert = GameAlert(title: "无法打开棋谱", message: "文件不是有效的 PGN 棋谱。")
            return
        }
        reviewTotal = loaded.moves.count
        var parts: [String] = []
        if !loaded.redName.isEmpty || !loaded.blackName.isEmpty {
            parts.append("\(loaded.redName) 对 \(loaded.blackName)")
        }
        if !loaded.result.isEmpty { parts.append("结果 \(loaded.result)") }
        if !loaded.event.isEmpty { parts.append(loaded.event) }
        comment = parts.isEmpty ? nil : parts.joined(separator: " · ")
        rebuildReview(0)
    }

    private func rebuildReview(_ index: Int) {
        guard let url = setup.recordURL, let loaded = try? XiangqiPgn.load(url) else { return }
        let g = XiangqiGame()
        if !loaded.fen.isEmpty { _ = g.loadFen(loaded.fen) }

        var notations: [String] = []
        let count = min(index, loaded.moves.count)
        for i in 0..<count {
            guard g.playUci(loaded.moves[i]) else { break }
            if let last = g.history.last { notations.append(g.notation(last)) }
        }
        game = g
        reviewIndex = count
        reviewMoves = notations
        lastMoveText = notations.last ?? ""
        clearSelection()
        refresh()
    }

    var moveLogText: String {
        let moves = mode == .review ? reviewMoves : lastMoveTexts
        return moves.joined(separator: "  ")
    }

    // MARK: - 内部

    private func flash(_ text: String) {
        transientStatus = text
        transientToken += 1
        let token = transientToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.transientToken == token else { return }
            if self.transientStatus != nil {
                self.transientStatus = nil
                self.refresh()
            }
        }
    }

    private func refresh() {
        objectWillChange.send()
    }
}
