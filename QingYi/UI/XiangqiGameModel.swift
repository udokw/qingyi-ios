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
    private var moveLog: [String] = []
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

        // 高档位用 Pikafish: 提前在后台加载网络, 避免第一次落子时明显卡顿
        if setup.mode == .ai, setup.level >= PikafishEngine.minimumLevel {
            DispatchQueue.global(qos: .utility).async {
                PikafishEngine.shared.preload()
            }
        }
    }

    // MARK: - 状态

    var leftTitle: String {
        switch mode {
        case .ai: return playerColor == .red ? "我执红" : "我执黑"
        case .local: return "本地双人"
        case .review: return "复 盘"
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

    var turnMarker: String { game.turn == .red ? "● 红方" : "● 黑方" }

    var plainStatus: String? {
        if let transientStatus { return transientStatus }
        if let resultText { return resultText }
        if mode == .review { return "\(reviewIndex) / \(reviewTotal) 着" }
        if thinking { return "对方思考中…" }
        return nil
    }

    /// 粉彩：整行状态（左执子 + 轮到）
    var monumentStatus: String {
        if let plain = plainStatus { return plain }
        let prefix: String
        switch mode {
        case .ai: prefix = playerColor == .red ? "我执红  " : "我执黑  "
        case .local: prefix = "本地双人  "
        case .review: prefix = ""
        }
        var s = prefix + "轮到 " + turnMarker + "行棋"
        if game.inCheck(game.turn) { s += " · 将军！" }
        return s
    }

    var eyebrowText: String {
        let n = mode == .review ? reviewIndex : game.plies
        if mode == .review {
            if n == 0 { return "象棋 · 复盘 · 开头" }
            return "象棋 · 复盘 · 第 \(ChineseNumber.text(n)) 着"
        }
        return "象棋 · 第 \(ChineseNumber.text(max(n, 1))) 着"
    }

    /// 最近 8 着中文记谱
    var moveLine: String {
        guard !moveLog.isEmpty else { return "楚河汉界 · 静待落子" }
        let start = max(0, moveLog.count - 8)
        var parts: [String] = []
        for i in start..<moveLog.count {
            parts.append(i % 2 == 0 ? "\(i / 2 + 1). \(moveLog[i])" : moveLog[i])
        }
        return parts.joined(separator: "  ")
    }

    var detailSubtitle: String {
        if mode == .review { return "9 × 10 · 棋谱复盘" }
        if mode == .ai { return "9 × 10 · 等级 \(level)" }
        return "9 × 10 · 本地双人"
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
            moveLog.append(lastMoveText)
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
            var move: XiangqiGame.Move?
            if level >= PikafishEngine.minimumLevel,
               let engineMove = PikafishEngine.shared.bestMove(fen: snapshot.fen, level: level) {
                move = XiangqiGame.Move(from: engineMove.from, to: engineMove.to)
            }
            // 引擎不可用 (资源缺失/超时) 时回退到本地 AI
            if move == nil {
                move = XiangqiAI.bestMove(in: snapshot, level: level)
            }
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
                    self.moveLog.append(self.lastMoveText)
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
        var undone = 0
        if mode == .ai {
            if game.plies > 0 { _ = game.undo(); undone += 1 }
            if game.plies > 0, game.turn != playerColor { _ = game.undo(); undone += 1 }
        } else {
            _ = game.undo()
            undone = 1
        }
        if undone > 0 { moveLog.removeLast(min(undone, moveLog.count)) }
        resultText = nil
        clearSelection()
        lastMoveText = moveLog.last ?? ""
        refresh()
        flash("已悔棋")
    }

    func restart() {
        guard mode == .ai else { return }
        game = XiangqiGame()
        moveLog.removeAll()
        lastMoveText = ""
        resultText = nil
        generation += 1
        thinking = false
        clearSelection()
        refresh()
        if game.turn != playerColor { startAI() }
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
        moveLog = notations
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
