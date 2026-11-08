import Foundation
import Combine

struct GameAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String?
    /// 否定按钮文案；nil 时沿用「取消 / 返回主页」的默认规则。
    var cancelTitle: String?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

final class GoGameModel: ObservableObject {
    let setup: GoSetup
    private(set) var game: GoGame
    let mode: PlayMode
    let playerColor: GoColor
    let level: Int
    let handicap: Int

    @Published var thinking = false
    @Published var territory: [[Int]]?
    @Published var alert: GameAlert?
    @Published var resultText: String?
    @Published var transientStatus: String?
    @Published var shareItem: ShareItem?
    @Published var reviewIndex = 0
    @Published var reviewTotal = 0
    @Published var comment: String?

    private var sgfGame: Sgf.Game?
    private var sgfNodes: [Sgf.Node] = []
    private var transientToken = 0
    private var territoryToken = 0
    private var generation = 0

    init(setup: GoSetup) {
        self.setup = setup
        self.game = GoGame(size: setup.size)
        self.mode = setup.mode
        self.playerColor = setup.playerColor
        self.level = setup.level
        self.handicap = setup.handicap

        if setup.mode == .review {
            if let url = setup.recordURL {
                loadReview(url)
            }
        } else if setup.mode == .ai, setup.handicap > 0 {
            game.placeHandicap(GoGameModel.handicapPoints(size: setup.size, count: setup.handicap))
        }

        if setup.mode == .ai, game.turn != playerColor {
            DispatchQueue.main.async { [weak self] in
                self?.startAI()
            }
        }

        // 提前在后台加载对应档位的引擎:
        // 1-3 级用本地 AI 感知 (无需预加载), 4-6 级用 Pachi, 7-10 级用 KataGo
        if setup.mode == .ai {
            if setup.level >= KataGoEngine.minimumLevel {
                DispatchQueue.global(qos: .utility).async {
                    KataGoEngine.shared.preload()
                }
            } else if setup.level >= PachiEngine.minimumLevel {
                let level = setup.level
                DispatchQueue.global(qos: .utility).async {
                    PachiEngine.shared.preload(level: level)
                }
            }
        }
    }

    // MARK: - 状态文案

    var leftTitle: String {
        switch mode {
        case .ai: return playerColor == .black ? "● 我执黑" : "○ 我执白"
        case .local: return "本地双人"
        case .review: return "打 谱"
        }
    }

    var subTitle: String {
        switch mode {
        case .ai:
            var text = "\(game.size) 路 · 等级 \(level)"
            if handicap > 0 { text += " · 让 \(handicap) 子" }
            return text
        case .local: return "\(game.size) 路 · 本地双人"
        case .review: return "\(game.size) 路 · 棋谱打谱"
        }
    }

    var statusText: String {
        if let transientStatus { return transientStatus }
        if let resultText { return resultText }
        if mode == .review { return "\(reviewIndex) / \(reviewTotal) 手" }
        if thinking { return "对方思考中…" }
        return game.turn == .black ? "轮到 黑方 行棋" : "轮到 白方 行棋"
    }

    /// 非「轮到 XX 行棋」时的纯文本状态
    var plainStatus: String? {
        if let transientStatus { return transientStatus }
        if let resultText { return resultText }
        if mode == .review { return "手数 \(reviewIndex) / \(reviewTotal)" }
        if thinking { return "对方思考中…" }
        return nil
    }

    var turnMarker: String { game.turn == .black ? "● 黑方" : "○ 白方" }

    /// 粉彩：整行状态（左执子 + 轮到）
    var monumentStatus: String {
        if let plainStatus { return plainStatus }
        let prefix: String
        switch mode {
        case .ai: prefix = playerColor == .black ? "我执黑  " : "我执白  "
        case .local: prefix = "本地双人  "
        case .review: prefix = ""
        }
        return prefix + "轮到 " + turnMarker + "行棋"
    }

    /// 墨白：眉题「对局 · 第 X 手」
    var eyebrowText: String {
        let n = mode == .review ? reviewIndex : game.history.count
        if mode == .review {
            if n == 0 { return "棋谱 · 开头" }
            return "棋谱 · 第 \(ChineseNumber.text(n)) 手"
        }
        return "对局 · 第 \(ChineseNumber.text(max(n, 1))) 手"
    }

    var lastMove: GoPoint? { game.history.last?.point }
    var isFinished: Bool { resultText != nil }

    // MARK: - 落子

    func tap(_ x: Int, _ y: Int) {
        guard mode != .review, !thinking, !isFinished else { return }
        if mode == .ai, game.turn != playerColor { return }
        guard game.play(x, y) != nil else { return }
        SoundPlayer.shared.playStone()
        refresh()
        afterMove()
    }

    func pass() {
        guard mode != .review, !thinking, !isFinished else { return }
        if mode == .ai, game.turn != playerColor { return }
        _ = game.pass()
        SoundPlayer.shared.playStone()
        refresh()
        afterMove()
    }

    private func afterMove() {
        if twoPasses() {
            finishByScore(title: "双方停一手 · 对局结束")
            return
        }
        if mode == .ai, game.turn != playerColor {
            startAI()
        }
    }

    private func twoPasses() -> Bool {
        let hs = game.history
        guard hs.count >= 2 else { return false }
        return hs[hs.count - 1].point == nil && hs[hs.count - 2].point == nil
    }

    // MARK: - AI

    private func startAI() {
        guard mode == .ai, !thinking, !isFinished else { return }
        thinking = true
        let board = game.board
        let size = game.size
        let color = game.turn
        let ko = game.ko
        let level = level
        let last = lastMove
        let komi = game.komi
        let history = game.history
        let gen = generation

        DispatchQueue.global(qos: .userInitiated).async {
            var move: GoPoint?
            var engineHandled = false
            if level >= KataGoEngine.minimumLevel {
                switch KataGoEngine.shared.bestMove(size: size, komi: komi, history: history,
                                                    board: board, color: color, level: level) {
                case .move(let point):
                    move = point
                    engineHandled = true
                case .pass:
                    engineHandled = true
                case .unavailable:
                    break
                }
            } else if level >= PachiEngine.minimumLevel {
                switch PachiEngine.shared.bestMove(size: size, komi: komi, history: history,
                                                   board: board, color: color, level: level) {
                case .move(let point):
                    move = point
                    engineHandled = true
                case .pass:
                    engineHandled = true
                case .unavailable:
                    break
                }
            }
            if !engineHandled {
                move = GoAI.bestMove(board: board, size: size, color: color,
                                     ko: ko, level: level, lastMove: last)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.thinking = false
                if let move {
                    if self.game.play(move.x, move.y) == nil {
                        _ = self.game.pass()
                    }
                } else {
                    _ = self.game.pass()
                }
                SoundPlayer.shared.playStone()
                self.refresh()
                if self.twoPasses() {
                    self.finishByScore(title: "双方停一手 · 对局结束")
                } else {
                    self.flash("对方落子")
                }
            }
        }
    }

    // MARK: - 操作

    func undo() {
        guard !thinking else { return }
        if mode == .review { reviewStep(-1); return }
        guard game.canUndo else {
            flash("无法悔棋")
            return
        }
        if mode == .local {
            _ = game.undo()
        } else {
            _ = game.undo()
            if game.turn != playerColor, game.canUndo {
                _ = game.undo()
            }
        }
        resultText = nil
        territory = nil
        refresh()
        flash("已悔棋")
    }

    func estimate() {
        guard !thinking else { return }
        let t = game.territoryMap()
        territory = t
        territoryToken += 1
        let token = territoryToken
        let s = game.chineseScore()
        flash("形势: 黑 \(Int(s.black)) 白 \(Int(s.white))（子空皆地）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.territoryToken == token else { return }
            self.territory = nil
        }
    }

    func countScore() {
        let s = game.chineseScore()
        let whiteTotal = s.white + game.komi
        let diff = s.black - whiteTotal
        let outcome: String
        if abs(diff) < 0.5 {
            outcome = "和棋"
        } else if diff > 0 {
            outcome = "黑胜 \(String(format: "%.1f", diff)) 子"
        } else {
            outcome = "白胜 \(String(format: "%.1f", -diff)) 子"
        }
        alert = GameAlert(title: "数子结果",
                          message: "黑 \(String(format: "%.0f", s.black)) 子 · 白 \(String(format: "%.1f", whiteTotal)) 子（含贴目）\n\(outcome)")
    }

    func resign() {
        guard !isFinished, mode != .review, !thinking else { return }
        let isBlack = mode == .ai ? playerColor == .black : (game.turn == .black)
        alert = GameAlert(title: "确认认输",
                          message: "认输后本局结束，可在悔棋中恢复。",
                          confirmTitle: "确认认输") { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.resultText = isBlack ? "黑方认输" : "白方认输"
            self.refresh()
        }
    }

    func save() {
        guard mode != .review else { return }
        let blackName: String
        let whiteName: String
        if mode == .ai {
            blackName = playerColor == .black ? "我" : "清弈"
            whiteName = playerColor == .white ? "我" : "清弈"
        } else {
            blackName = "黑方"
            whiteName = "白方"
        }
        do {
            let url = try Sgf.saveToDocuments(game, blackName: blackName, whiteName: whiteName, result: resultText)
            shareItem = ShareItem(url: url, title: "棋谱已保存")
        } catch {
            alert = GameAlert(title: "保存失败", message: error.localizedDescription)
        }
    }

    // MARK: - 复盘

    func reviewStep(_ delta: Int) {
        let next = min(max(0, reviewIndex + delta), reviewTotal)
        guard next != reviewIndex else { return }
        rebuildReview(next)
    }

    private func loadReview(_ url: URL) {
        guard let loaded = try? Sgf.load(url) else {
            alert = GameAlert(title: "无法打开棋谱", message: "文件不是有效的 SGF 棋谱。")
            return
        }
        sgfGame = loaded
        sgfNodes = loaded.nodes
        reviewTotal = loaded.nodes.count
        rebuildReview(0)
    }

    private func rebuildReview(_ index: Int) {
        guard let sgf = sgfGame else { return }
        let g = GoGame(size: sgf.size)
        g.komi = sgf.komi
        if !sgf.setupBlack.isEmpty || !sgf.setupWhite.isEmpty || !sgf.setupEmpty.isEmpty {
            g.setup(black: sgf.setupBlack, white: sgf.setupWhite,
                    empty: sgf.setupEmpty, toMove: sgf.playerToMove)
        }
        for i in 0..<min(index, sgfNodes.count) {
            let node = sgfNodes[i]
            if node.color == .empty { continue }
            if let p = node.point {
                if g.turn != node.color { _ = g.pass() }
                _ = g.play(p.x, p.y)
            } else {
                _ = g.pass()
            }
        }
        game = g
        reviewIndex = index
        comment = index > 0 && index <= sgfNodes.count ? sgfNodes[index - 1].comment : nil
        refresh()
    }

    // MARK: - 内部

    private func finishByScore(title: String) {
        let s = game.chineseScore()
        let whiteTotal = s.white + game.komi
        let diff = s.black - whiteTotal
        let outcome: String
        if abs(diff) < 0.5 {
            outcome = "和棋"
        } else if diff > 0 {
            outcome = "黑胜 \(String(format: "%.1f", diff)) 子"
        } else {
            outcome = "白胜 \(String(format: "%.1f", -diff)) 子"
        }
        resultText = outcome
        generation += 1
        thinking = false
        alert = GameAlert(title: title,
                          message: "黑 \(String(format: "%.0f", s.black)) 子 · 白 \(String(format: "%.1f", whiteTotal)) 子（含贴目）\n\(outcome)")
    }

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

    static func handicapPoints(size: Int, count: Int) -> [GoPoint] {
        guard count > 0 else { return [] }
        let low = size >= 13 ? 3 : 2
        let high = size - 1 - low
        let mid = size / 2
        let corners = [GoPoint(x: low, y: low), GoPoint(x: high, y: low),
                       GoPoint(x: low, y: high), GoPoint(x: high, y: high)]
        switch count {
        case 1: return [GoPoint(x: low, y: high)]
        case 2: return [corners[0], corners[3]]
        case 3: return [corners[0], corners[1], corners[3]]
        case 4: return corners
        case 5: return corners + [GoPoint(x: mid, y: mid)]
        case 6: return corners + [GoPoint(x: mid, y: low), GoPoint(x: mid, y: high)]
        case 7: return corners + [GoPoint(x: mid, y: mid), GoPoint(x: mid, y: low), GoPoint(x: mid, y: high)]
        case 8: return corners + [GoPoint(x: mid, y: low), GoPoint(x: mid, y: high),
                                  GoPoint(x: low, y: mid), GoPoint(x: high, y: mid)]
        default: return corners + [GoPoint(x: mid, y: mid), GoPoint(x: mid, y: low), GoPoint(x: mid, y: high),
                                   GoPoint(x: low, y: mid), GoPoint(x: high, y: mid)]
        }
    }
}
