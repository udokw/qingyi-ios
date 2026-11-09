import Foundation
import Combine

/// 暗棋单机模型：人机 / 本地双人。横屏对局，操作面板由返回键、长按或右下 ⋯ 呼出。
/// 规则与文案对齐 Android `banqi/BanqiActivity`。
final class BanqiGameModel: ObservableObject {
    let mode: PlayMode
    let playerSeat: Int

    private(set) var game: BanqiGame
    @Published private(set) var codes: [[Int]] = []
    @Published private(set) var faceUp: [[Bool]] = []
    @Published var selection: GoPoint?
    @Published private(set) var legalTargets: [GoPoint] = []
    @Published var alert: GameAlert?
    @Published private(set) var transientStatus: String?
    @Published private(set) var thinking = false
    @Published private(set) var level: Int

    /// 座位 2 把整盘翻转 180°，与 Android 的翻转显示一致。
    var flipped: Bool { playerSeat == BanqiGame.seatSecond && mode == .ai }
    var playerColor: Int { game.colorOfSeat(playerSeat) }

    private var aiToken = 0
    private var transientToken = 0
    private var endShown = false

    init(setup: BanqiSetup) {
        mode = setup.mode
        playerSeat = setup.first ? BanqiGame.seatFirst : BanqiGame.seatSecond
        level = max(1, min(10, setup.level))
        game = BanqiGame()
        sync()
        if mode == .ai, game.turnSeat != playerSeat {
            startAI()
        }
    }

    // MARK: - 常驻 HUD

    var turnText: String {
        if thinking { return "AI 思考中…" }
        if game.isOver { return game.endReason }
        if let color = colorIfKnown() {
            return (color == BanqiGame.red ? "红方" : "黑方") + "行棋"
        }
        return game.turnSeat == BanqiGame.seatFirst ? "● 先手行棋" : "○ 后手行棋"
    }

    var countText: String {
        var red = 0, black = 0, hidden = 0
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                let p = codes[y][x]
                if p == BanqiGame.empty { continue }
                if !faceUp[y][x] { hidden += 1; continue }
                if BanqiGame.colorOf(p) == BanqiGame.red { red += 1 } else { black += 1 }
            }
        }
        return "红 \(red) · 黑 \(black) · 暗 \(hidden)"
    }

    private func colorIfKnown() -> Int? {
        let c = game.colorOfSeat(game.turnSeat)
        return c == 0 ? nil : c
    }

    var levelText: String { "\(level) 段" }

    // MARK: - 操作

    func tap(_ x: Int, _ y: Int) {
        guard !game.isOver, !thinking else { return }
        if mode == .ai, game.turnSeat != playerSeat { return }

        let p = game.pieceCodeAt(x, y)
        let up = game.isFaceUp(x, y)

        // 点到自己的明子：选中 / 换选
        if p != BanqiGame.empty, up, BanqiGame.colorOf(p) == game.turnColor {
            if selection?.x == x && selection?.y == y {
                clearSelection()
            } else {
                selection = GoPoint(x: x, y: y)
                legalTargets = game.legalMovesFrom(x, y).map { GoPoint(x: $0.tx, y: $0.ty) }
            }
            return
        }

        // 已选中 → 尝试走子 / 吃子
        if selection != nil {
            if game.play(fromX: selection!.x, fromY: selection!.y, toX: x, toY: y) {
                SoundPlayer.shared.playMove()
                afterAction()
                return
            }
            if p != BanqiGame.empty {
                transient("不能吃这枚子")
            } else {
                transient("这步不合规则")
            }
            return
        }

        // 未选中 → 点暗子翻子
        if p == BanqiGame.hidden || (p != BanqiGame.empty && !up) {
            if game.flip(x: x, y: y) {
                SoundPlayer.shared.playMove()
                afterAction()
                return
            }
            transient("这步不合规则")
            return
        }

        if p != BanqiGame.empty {
            transient("请先选中己方明子")
        }
    }

    func undo() {
        guard !thinking else { return }
        guard game.undo() != nil else {
            transient("还没有落子可悔")
            return
        }
        if mode == .ai, game.historySnapshot().count > 0, game.turnSeat != playerSeat, !game.isOver {
            _ = game.undo()
        }
        endShown = false
        clearSelection()
        sync()
    }

    func resign() {
        guard !game.isOver else { return }
        let seat = mode == .ai ? playerSeat : game.turnSeat
        let who = game.colorOfSeat(seat) == BanqiGame.red ? "红方"
            : (game.colorOfSeat(seat) == BanqiGame.black ? "黑方" : "当前一方")
        let a = GameAlert(title: "认 输", message: "确认由\(who)认输?", confirmTitle: "认输",
                          cancelTitle: "继续") { [weak self] in
            self?.game.resign(seat: seat)
            self?.selection = nil
            self?.legalTargets = []
            self?.sync()
            self?.presentEndIfNeeded()
        }
        alert = a
    }

    func restart() {
        aiToken += 1
        game = BanqiGame()
        thinking = false
        endShown = false
        clearSelection()
        sync()
        if mode == .ai, game.turnSeat != playerSeat {
            startAI()
        }
    }

    func cycleLevel() {
        level = level >= 10 ? 1 : level + 1
    }

    func setLevel(_ value: Int) {
        level = max(1, min(10, value))
    }

    // MARK: - AI

    private func startAI() {
        guard mode == .ai, !game.isOver else { return }
        thinking = true
        let copy = game.copyForSearch()
        let lv = level
        aiToken += 1
        let token = aiToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let move = BanqiAi.choose(in: copy, level: lv)
            DispatchQueue.main.async {
                guard let self, self.aiToken == token else { return }
                self.thinking = false
                guard let move, !self.game.isOver else { return }
                if self.game.play(move) {
                    SoundPlayer.shared.playMove()
                }
                self.clearSelection()
                self.sync()
                self.presentEndIfNeeded()
            }
        }
    }

    private func afterAction() {
        clearSelection()
        sync()
        if presentEndIfNeeded() { return }
        if mode == .ai, game.turnSeat != playerSeat {
            startAI()
        }
    }

    @discardableResult
    private func presentEndIfNeeded() -> Bool {
        guard game.isOver, !endShown else { return game.isOver }
        endShown = true
        let title: String
        if game.result == BanqiGame.resultDraw {
            title = "和 棋"
        } else if game.result == BanqiGame.red {
            title = "红方胜"
        } else {
            title = "黑方胜"
        }
        alert = GameAlert(title: title, message: game.endReason,
                          confirmTitle: "再来一局", cancelTitle: "返回主页") { [weak self] in
            self?.restart()
        }
        return true
    }

    // MARK: - 内部

    private func clearSelection() {
        selection = nil
        legalTargets = []
    }

    private func sync() {
        codes = game.boardCodes
        faceUp = game.faceUpGrid
        if game.isOver { clearSelection() }
    }

    private func transient(_ text: String) {
        transientToken += 1
        let token = transientToken
        transientStatus = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.transientToken == token else { return }
            self.transientStatus = nil
        }
    }

    var lastActionText: String {
        if let t = transientStatus { return t }
        if let m = game.lastMove { return game.notation(m) }
        return "翻开第一枚暗子"
    }
}
