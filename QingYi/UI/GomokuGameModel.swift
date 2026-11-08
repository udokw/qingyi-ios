import Foundation
import Combine

/// 五子棋单机模型：人机 / 本地双人 / 读谱回放。
/// 规则与文案对齐 Android `GomokuActivity`。
final class GomokuGameModel: ObservableObject {
    let mode: PlayMode
    let playerColor: Int
    let level: Int
    private(set) var renju: Bool
    private let hintsEnabled: Bool
    private(set) var game: GomokuGame

    @Published private(set) var board: [[Int]] = []
    @Published private(set) var turn: Int = GomokuGame.black
    @Published private(set) var lastMove: GoPoint?
    @Published private(set) var winLine: (GoPoint, GoPoint)?
    @Published private(set) var hint: GoPoint?
    @Published var alert: GameAlert?
    @Published private(set) var resultText: String?
    @Published private(set) var transientStatus: String?
    @Published private(set) var thinking = false
    @Published private(set) var replaying = false

    private var aiToken = 0
    private var transientToken = 0
    /// 认输等非五连终局的 SGF 结果码（B+R / W+R），存谱时写入 RE。
    private var endResultCode = ""

    init(setup: GomokuSetup) {
        mode = setup.mode
        playerColor = setup.playerColor
        level = setup.level
        renju = setup.renju
        hintsEnabled = setup.hints
        game = GomokuGame()
        game.isRenju = setup.renju
        sync()
        maybeStartAI()
    }

    // MARK: - 状态文案

    var isOver: Bool { game.isOver || game.isFull() }

    /// 墨白大标题：我执黑 / 本地双人
    var leftTitle: String {
        if mode == .local { return "本地双人" }
        return playerColor == GomokuGame.black ? "● 我执黑" : "○ 我执白"
    }

    var subTitle: String {
        let forb = renju ? "黑棋禁手" : "无禁手"
        if mode == .ai {
            return "19 路 · \(forb) · 自研 AI · \(GomokuAi.levelName(level))"
        }
        return "19 路 · \(forb) · 同机双人"
    }

    var eyebrowText: String {
        "五 子 棋 · 第 \(GomokuGameModel.han(game.moveCount)) 手"
    }

    var statusText: String {
        if let transientStatus { return transientStatus }
        if let resultText { return resultText }
        if thinking { return "AI 思考中…" }
        if mode == .local {
            return "轮到 \(turn == GomokuGame.black ? "黑方" : "白方")行棋"
        }
        return "轮到 \(turn == GomokuGame.black ? "黑方" : "白方")行棋"
    }

    var plainStatus: String? {
        if let transientStatus { return transientStatus }
        if let resultText { return resultText }
        if thinking { return "AI 思考中…" }
        return nil
    }

    var turnMarker: String { turn == GomokuGame.black ? "● 黑方" : "○ 白方" }

    var canUndo: Bool { game.canUndo }

    // MARK: - 落子

    func tap(_ x: Int, _ y: Int) {
        guard !isOver, !thinking else { return }
        if mode == .ai, turn != playerColor { return }
        let code = game.tryPlay(x, y)
        switch code {
        case GomokuGame.playOK:
            hint = nil
            clearTransient()
            sync()
            finishIfNeeded()
            // 关键：玩家落子后必须由这里把回合交给 AI。
            // 之前只有 init / restart 调 startAI，玩家（黑）落完子就再没人叫 AI，界面永远停住。
            maybeStartAI()
        case GomokuGame.playForbidden:
            transientStatus = "黑棋禁手：\(game.forbiddenText(x, y))"
            scheduleTransientClear()
            sync()
        default:
            break
        }
    }

    // MARK: - AI

    /// 玩家落子 / 悔棋 / 读谱之后，轮到 AI 时自动接手。
    private func maybeStartAI() {
        guard GomokuSoloTurn.needsAI(isAIMode: mode == .ai,
                                     playerColor: playerColor,
                                     turn: game.turn,
                                     isOver: isOver,
                                     isFull: game.isFull()) else { return }
        startAI()
    }

    private func startAI() {
        guard mode == .ai, !isOver else { return }
        thinking = true
        hint = nil
        let snapshotBoard = game.copyBoard()
        let n = game.size
        let me = game.turn
        let lv = level
        let renjuNow = game.isRenju
        aiToken += 1
        let token = aiToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mv = GomokuSoloTurn.chooseMove(board: snapshotBoard, size: n, me: me,
                                               level: lv, renju: renjuNow)
            DispatchQueue.main.async {
                guard let self, self.aiToken == token else { return }
                self.thinking = false
                guard !self.isOver else { return }
                var moved = false
                if let mv, self.game.tryPlay(mv.x, mv.y) == GomokuGame.playOK {
                    moved = true
                }
                // 兜底：选点为空或落在禁手点（黑棋禁手把候选全过滤掉）时，
                // 依次试任意空点，避免 AI 回合静默卡死。
                if !moved { moved = self.playFirstLegalMove() }
                if moved {
                    self.clearTransient()
                } else if !self.game.isFull() {
                    self.transientStatus = "AI 没有合法落点，请悔棋或开新局"
                }
                self.sync()
                self.finishIfNeeded()
                if self.hintsEnabled, self.mode == .ai, !self.isOver,
                   self.game.turn == self.playerColor {
                    self.requestHint()
                }
            }
        }
    }

    /// 依次尝试棋盘上的空点（会自动跳过禁手点），成功返回 true。
    private func playFirstLegalMove() -> Bool {
        for y in 0..<game.size {
            for x in 0..<game.size {
                if game.isEmpty(x, y), game.tryPlay(x, y) == GomokuGame.playOK {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - 操作

    func undo() {
        guard !thinking else { return }
        guard game.canUndo else {
            transientStatus = "还没有落子可悔"
            scheduleTransientClear()
            return
        }
        _ = game.undo()
        if mode == .ai, game.canUndo, game.turn != playerColor, !game.isOver {
            _ = game.undo()
        }
        resultText = nil
        hint = nil
        clearTransient()
        sync()
        maybeStartAI()
    }

    func resign() {
        guard !isOver else { return }
        let message: String
        if mode == .ai {
            message = "确定向 AI 认输?"
        } else {
            message = turn == GomokuGame.black ? "确定替黑方认输?" : "确定替白方认输?"
        }
        alert = GameAlert(title: "认输", message: message, confirmTitle: "认输",
                          cancelTitle: "继续对局") { [weak self] in
            self?.performResign()
        }
    }

    private func performResign() {
        let loser = mode == .ai ? playerColor : turn
        let winner = 3 - loser
        let loserName = loser == GomokuGame.black ? "黑方" : "白方"
        let winnerName = winner == GomokuGame.black ? "黑方" : "白方"
        endResultCode = (winner == GomokuGame.black ? "B" : "W") + "+R"
        if mode == .ai {
            transientStatus = "\(GomokuAi.levelName(level)) · \(loserName)认输"
        } else {
            transientStatus = "\(loserName)认输"
        }
        resultText = "\(winnerName)获胜（\(loserName)认输），共 \(game.moveCount) 手。"
        hint = nil
        sync()
        // 与 Android showResult(false) 相同：认输后弹「对局结束」框
        let text = resultText ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.alert = GameAlert(title: "对局结束", message: text,
                                   confirmTitle: "再来一局", cancelTitle: "返回主页") {
                self.restart()
            }
        }
    }

    func requestHint() {
        guard !isOver, !thinking else { return }
        if mode == .ai, turn != playerColor { return }
        transientStatus = "正在计算提示…"
        let snapshotBoard = game.copyBoard()
        let n = game.size
        let me = turn
        let lv = level
        let renjuNow = game.isRenju
        aiToken += 1
        let token = aiToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mv = GomokuSoloTurn.chooseMove(board: snapshotBoard, size: n, me: me,
                                               level: lv, renju: renjuNow)
            DispatchQueue.main.async {
                guard let self, self.aiToken == token else { return }
                guard let mv else {
                    self.transientStatus = "棋盘已满，没有可提示的点"
                    self.scheduleTransientClear()
                    return
                }
                self.hint = GoPoint(x: mv.x, y: mv.y)
                self.transientStatus = "提示：\(GomokuGameModel.coordinate(mv.x, mv.y))（\(me == GomokuGame.black ? "黑" : "白")）"
                self.scheduleTransientClear()
            }
        }
    }

    func toggleRenju() {
        guard game.moveCount == 0 else {
            alert = GameAlert(title: "禁手", message: "已有落子，切换禁手请先开新局。")
            return
        }
        renju.toggle()
        game.isRenju = renju
        transientStatus = renju
            ? "黑棋禁手已开：长连 / 四四 / 三三判负"
            : "已切回无禁手（freestyle）"
        scheduleTransientClear()
    }

    func restart() {
        aiToken += 1
        game.clear()
        game.isRenju = renju
        endResultCode = ""
        hint = nil
        resultText = nil
        transientStatus = nil
        thinking = false
        replaying = false
        sync()
        maybeStartAI()
    }

    // MARK: - 存谱 / 读谱

    func saveRecord() {
        guard game.moveCount > 0 else {
            transientStatus = "还没有落子，暂无可存的棋谱"
            scheduleTransientClear()
            return
        }
        let blackName: String
        let whiteName: String
        if mode == .ai {
            let ai = "自研AI \(GomokuAi.levelName(level))"
            blackName = playerColor == GomokuGame.black ? "我" : ai
            whiteName = playerColor == GomokuGame.white ? "我" : ai
        } else {
            blackName = "黑方"
            whiteName = "白方"
        }
        do {
            let url = try GomokuRecord.saveToFile(game, blackName: blackName, whiteName: whiteName,
                                                  result: recordResult(),
                                                  directory: GomokuGameModel.recordsDirectory)
            alert = GameAlert(title: "存谱", message: "已保存：\(url.lastPathComponent)")
        } catch {
            alert = GameAlert(title: "存谱失败", message: error.localizedDescription)
        }
    }

    static var recordsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("清弈", isDirectory: true)
    }

    private func recordResult() -> String {
        if !endResultCode.isEmpty { return endResultCode }
        if game.isOver {
            return game.winner == GomokuGame.black ? "B+5" : "W+5"
        }
        if game.isFull() { return "0" }
        return ""
    }

    func records() -> [URL] {
        GomokuRecord.list(in: GomokuGameModel.recordsDirectory)
    }

    /// 读取棋谱：逐手重放到终局，之后可继续对弈（与 Android 回放完成后的行为一致）。
    func loadRecord(_ url: URL) {
        guard let data = try? GomokuRecord.load(file: url) else {
            alert = GameAlert(title: "棋谱读取失败", message: "无法解析该 SGF 文件")
            return
        }
        guard !data.moves.isEmpty else {
            alert = GameAlert(title: "读谱", message: "棋谱里没有着法")
            return
        }
        aiToken += 1
        let g = GomokuGame(size: data.size > 0 ? data.size : GomokuGame.boardSize)
        g.isRenju = data.renju
        for move in data.moves {
            guard g.play(move.x, move.y) else { break }
        }
        game = g
        renju = g.isRenju
        // 与 Android 一致：读谱保留 RE，重新存谱时不会丢结果
        endResultCode = data.result
        thinking = false
        hint = nil
        replaying = true
        resultText = nil
        transientStatus = "回放完成 · 共 \(g.moveCount) 手" + (g.isOver ? "" : "（可继续对弈）")
        sync()
        maybeStartAI()
    }

    func setAlert(_ a: GameAlert?) { alert = a }

    // MARK: - 内部

    /// 与 Android 一致：五连 / 棋盘已满 / 认输之后弹终局框。
    private func finishIfNeeded() {
        if game.isOver {
            let w = game.winner
            let wName = w == GomokuGame.black ? "黑方" : "白方"
            transientStatus = "\(wName)五连获胜"
            if mode == .ai {
                let title = w == playerColor ? "你赢了" : "AI 获胜"
                let msg = "\(wName)五连，"
                    + (w == playerColor ? "恭喜拿下本局。" : "再来一局试试。")
                alert = GameAlert(title: title, message: msg,
                                  confirmTitle: "再来一局", cancelTitle: "返回主页") { [weak self] in
                    self?.restart()
                }
            } else {
                alert = GameAlert(title: "\(wName)获胜",
                                  message: "五连达成，共 \(game.moveCount) 手。",
                                  confirmTitle: "再来一局", cancelTitle: "返回主页") { [weak self] in
                    self?.restart()
                }
            }
        } else if game.isFull() {
            transientStatus = "棋盘已满 · 和棋"
            alert = GameAlert(title: "对局结束",
                              message: "棋盘已满，和棋（共 \(game.moveCount) 手）。",
                              confirmTitle: "再来一局", cancelTitle: "返回主页") { [weak self] in
                self?.restart()
            }
        }
    }

    private func sync() {
        var rows: [[Int]] = []
        rows.reserveCapacity(game.size)
        for y in 0..<game.size {
            var row: [Int] = []
            row.reserveCapacity(game.size)
            for x in 0..<game.size { row.append(game.get(x, y)) }
            rows.append(row)
        }
        board = rows
        turn = game.turn
        lastMove = game.lastX >= 0 ? GoPoint(x: game.lastX, y: game.lastY) : nil
        if let w = game.winLine {
            winLine = (GoPoint(x: w.x1, y: w.y1), GoPoint(x: w.x2, y: w.y2))
        } else {
            winLine = nil
        }
    }

    private func clearTransient() {
        transientToken += 1
        transientStatus = nil
    }

    private func scheduleTransientClear() {
        transientToken += 1
        let token = transientToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.transientToken == token else { return }
            if self.resultText == nil { self.transientStatus = nil }
        }
    }

    // MARK: - 文案工具

    static func coordinate(_ x: Int, _ y: Int) -> String {
        // 与 Android 相同：列用大写字母（A 起），行号从棋盘底部往上数。
        String(Character(UnicodeScalar(UInt8(65 + x)))) + String(GomokuGame.boardSize - y)
    }

    static func han(_ n: Int) -> String {
        let d = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        if n <= 10 { return n == 10 ? "十" : d[n] }
        if n < 20 { return "十" + d[n - 10] }
        let a = n / 10
        let b = n % 10
        return d[a] + "十" + (b == 0 ? "" : d[b])
    }
}
