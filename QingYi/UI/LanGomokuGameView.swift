import SwiftUI

/// 联机五子棋：版式对齐 Android `activity_lan_gomoku.xml`。
/// 页头（我执X / 五子棋·房号+对手 / 当前状态 + 朱红「联」）
/// → 规则行 → 发丝线 → 时钟行（黑左白右）→ 左右贴屏棋盘
/// → 棋盘下一行状态 → 两行动作区（悔棋/提示/认输、存谱/离开）→ 页脚。
struct LanGomokuGameView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hub = LanHub.shared

    @State private var hint: GoPoint?
    @State private var hintMoveNo = -1
    @State private var hintWorking = false
    @State private var prompt: Prompt?
    @State private var shareItem: ShareItem?
    @State private var saveFailure = ""

    private var theme: Theme { app.theme }
    private var lineColor: Color { theme.isHara ? theme.divider : theme.dlgLine }

    private enum Prompt: Int, Identifiable {
        case resign, leave, saveFailed
        var id: Int { rawValue }
    }

    private struct ActionItem: Identifiable {
        let id: Int
        let title: String
        let en: String
        let danger: Bool
        let primary: Bool
        let run: () -> Void
    }

    var body: some View {
        GeometryReader { proxy in
            let m = Self.metrics(width: proxy.size.width, height: proxy.size.height)
            ZStack {
                PaperBackground(theme: theme)

                VStack(spacing: 0) {
                    headerRow
                        .padding(.horizontal, GameLayout.columnInset)
                        .padding(.top, 2)

                    ruleRow
                        .padding(.horizontal, GameLayout.columnInset)
                        .padding(.top, 10)

                    Hairline(color: lineColor)
                        .padding(.top, 8)

                    clockRow
                        .padding(.horizontal, GameLayout.columnInset)
                        .padding(.top, 6)
                        .padding(.bottom, 4)

                    boardArea(m.side)
                        .padding(.top, Self.boardTopGap)

                    stateLine
                        .padding(.horizontal, 8)
                        .padding(.top, Self.boardToStateGap)

                    controls
                        .padding(.top, Self.stateToControlsGap)

                    Spacer(minLength: 0)

                    footer
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                }
                .padding(.top, 4)

                if hub.state == .finished { resultOverlay }

                if hub.linkDown && hub.state == .playing {
                    VStack {
                        Spacer(minLength: 0)
                        Text("连接中断，正在重连…（计时已暂停，\(LanProto.reconnectGraceMs / 1000) 秒内未恢复将判负）")
                            .font(.system(size: 11))
                            .foregroundColor(theme.dangerText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.isHara ? Color.white.opacity(0.92) : Color.white.opacity(0.55))
                            )
                            .padding(.horizontal, 24)
                        Spacer().frame(height: 4)
                    }
                }
            }
        }
        .alert(item: $prompt) { item in
            switch item {
            case .resign:
                return Alert(title: Text("确认认输？"),
                             message: Text("认输后本局直接判负。"),
                             primaryButton: .destructive(Text("认输")) { hub.resign() },
                             secondaryButton: .cancel(Text("再想想")))
            case .leave:
                return Alert(title: Text("离开对局"),
                             message: Text("对局尚未结束，离开将中断连接。"),
                             primaryButton: .destructive(Text("离开")) { leave() },
                             secondaryButton: .cancel(Text("留下")))
            case .saveFailed:
                return Alert(title: Text("保存失败"),
                             message: Text(saveFailure),
                             dismissButton: .default(Text("好")))
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheetView(url: item.url, title: item.title)
        }
        .onAppear {
            SoundPlayer.shared.setEnabled(app.goSound)
        }
        .onChange(of: hub.moveNo) { _ in
            if hintMoveNo != hub.moveNo {
                hint = nil
                hintWorking = false
            }
        }
    }

    // MARK: - 数据

    private var board: [[Int]] {
        guard let g = hub.gomokuGame else {
            return Array(repeating: Array(repeating: GomokuGame.empty, count: GomokuGame.boardSize),
                         count: GomokuGame.boardSize)
        }
        var rows: [[Int]] = []
        for y in 0..<g.size {
            var row: [Int] = []
            for x in 0..<g.size { row.append(g.get(x, y)) }
            rows.append(row)
        }
        return rows
    }

    private var lastMove: GoPoint? {
        guard let m = hub.gomokuGame?.history.last else { return nil }
        return GoPoint(x: m.x, y: m.y)
    }

    private var winLine: (GoPoint, GoPoint)? {
        guard let w = hub.gomokuGame?.winLine else { return nil }
        return (GoPoint(x: w.x1, y: w.y1), GoPoint(x: w.x2, y: w.y2))
    }

    private var statusText: String {
        if hub.state == .finished { return "对局结束" }
        if hub.state != .playing { return "等待连接" }
        if hub.linkDown { return "重连中…" }
        if hub.isMyTurn { return hub.pendingMove ? "已发送…" : "轮到你落子" }
        return "等待对手落子"
    }

    // MARK: - 页头

    private var headerRow: some View {
        ZStack {
            VStack(spacing: 2) {
                Text("五子棋 · 房号 \(hub.roomCode)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(theme.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("我执\(hub.myColorName()) · 对手 \(hub.opponentName)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Self.headerSideReserve)

            HStack(alignment: .bottom, spacing: 0) {
                Text("我执\(hub.myColorName())")
                    .font(.system(size: 17))
                    .foregroundColor(theme.title)
                    .lineLimit(1)
                    .frame(width: Self.headerLeftWidth, alignment: .leading)

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("联")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: theme.isHara ? 2 : 5)
                                .fill(theme.accent)
                        )

                    Text(statusText)
                        .font(.system(size: 15))
                        .foregroundColor(hub.linkDown && hub.state == .playing ? theme.dangerText : theme.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.tail)
                        .frame(width: Self.headerRightWidth, height: Self.headerStatusLineHeight, alignment: .trailing)
                }
            }
        }
        .frame(height: Self.headerHeight)
    }

    private static let headerLeftWidth: CGFloat = 64
    private static let headerRightWidth: CGFloat = 76
    private static let headerHeight: CGFloat = 44
    private static let headerStatusLineHeight: CGFloat = 20
    private static let headerSideReserve: CGFloat = 78
    private static let boardTopGap: CGFloat = 8
    private static let boardToStateGap: CGFloat = 20
    private static let stateToControlsGap: CGFloat = 30

    private static func controlsHeight() -> CGFloat {
        0.8 + 2 * GameLayout.actionRowHeight + 0.8 + 0.8
    }

    private static func metrics(width: CGFloat, height: CGFloat) -> (side: CGFloat, boardTop: CGFloat) {
        let chromeTop: CGFloat = 4 + 2 + headerHeight + 10 + 16 + 8 + 0.8 + 6 + 34 + 4
        let chromeBottom: CGFloat = boardToStateGap + 16 + stateToControlsGap
            + controlsHeight() + 6 + 13 + 4
        let budget = max(0, height - chromeTop - boardTopGap - chromeBottom - 2)
        return (min(width, budget), chromeTop + boardTopGap)
    }

    // MARK: - 规则行

    private var ruleRow: some View {
        Text("19 路 · \(hub.gomokuRenju ? "黑棋禁手" : "无禁手") · \(hub.timerEnabled ? "计时" : "不计时")")
            .font(.system(size: 12))
            .foregroundColor(theme.sub)
            .frame(maxWidth: .infinity, alignment: .center)
            .lineLimit(1)
            .frame(height: 16)
    }

    // MARK: - 时钟行

    private var clockRow: some View {
        HStack(spacing: 0) {
            clockCell(seat: 1)
            Rectangle()
                .fill(lineColor)
                .frame(width: 0.8, height: 28)
            clockCell(seat: 2)
        }
        .frame(height: 34)
    }

    private func clockCell(seat: Int) -> some View {
        let active = hub.turn == seat && hub.state == .playing && !hub.linkDown
        return Text(hub.clockLabel(seat: seat))
            .font(.system(size: 18, weight: active ? .semibold : .regular))
            .foregroundColor(active ? theme.accent : theme.sub)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
    }

    // MARK: - 棋盘

    private func boardArea(_ side: CGFloat) -> some View {
        GomokuBoardView(board: board, size: GomokuGame.boardSize,
                        lastMove: lastMove, winLine: winLine, hint: hint,
                        theme: theme) { x, y in
            guard hub.state == .playing, hub.isMyTurn, !hub.pendingMove, !hub.linkDown else { return }
            hint = nil
            _ = hub.requestGomokuMove(x: x, y: y)
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 状态行

    private var stateLine: some View {
        Text(stateLineText)
            .font(.system(size: 12))
            .foregroundColor(theme.sub)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 16)
    }

    private var stateLineText: String {
        if let hint {
            return "提示：\(coordinate(hint.x, hint.y))（仅本机显示）"
        }
        if hub.state != .playing { return hub.state == .finished ? "对局已结束" : "等待对手加入…" }
        if hub.moveNo == 0 { return "开局 · 黑先" }
        return "第 \(hub.moveNo) 手 · \(hub.lastMoveText)"
    }

    private func coordinate(_ x: Int, _ y: Int) -> String {
        String(Character(UnicodeScalar(UInt8(65 + x)))) + String(GomokuGame.boardSize - y)
    }

    // MARK: - 动作区

    private var actionItems: [ActionItem] {
        var items: [ActionItem] = []
        items.append(ActionItem(id: 0, title: "悔棋", en: "UNDO", danger: false, primary: false) {
            hub.requestUndo()
        })
        if hub.hintsEnabled {
            items.append(ActionItem(id: 1, title: "提示", en: "HINT", danger: false, primary: false) {
                requestHint()
            })
        }
        items.append(ActionItem(id: 2, title: "认输", en: "RESIGN", danger: true, primary: false) {
            prompt = .resign
        })
        items.append(ActionItem(id: 3, title: "存谱", en: "SAVE SGF", danger: false, primary: false) {
            saveRecord()
        })
        items.append(ActionItem(id: 4, title: "离开", en: "LEAVE", danger: false, primary: false) {
            prompt = .leave
        })
        return items
    }

    private var rows: [[ActionItem]] {
        let items = actionItems
        guard !items.isEmpty else { return [] }
        var out: [[ActionItem]] = []
        var i = 0
        while i < items.count {
            let end = min(i + 3, items.count)
            out.append(Array(items[i..<end]))
            i = end
        }
        return out
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Hairline(color: lineColor)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Rectangle()
                                .fill(lineColor)
                                .frame(width: 0.8)
                        }
                        Button(action: item.run) {
                            GameActionCell(title: item.title, en: item.en,
                                           danger: item.danger, primary: item.primary,
                                           theme: theme)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: GameLayout.actionRowHeight)
                Hairline(color: lineColor)
            }
        }
    }

    private var footer: some View {
        Text("局 域 网 · 清 弈")
            .font(.system(size: 11))
            .tracking(2.6)
            .foregroundColor(theme.foot)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 提示 / 存谱

    /// 提示只在本地计算：快照 + 当前行棋方，与 Android LanGomokuActivity 相同。
    private func requestHint() {
        guard !hintWorking, hub.hintsEnabled, hub.state == .playing,
              !hub.linkDown, !hub.pendingMove, let g = hub.gomokuGame else { return }
        hintWorking = true
        let snapshot = g.copyBoard()
        let size = g.size
        let color = hub.turn
        let moveNo = hub.moveNo
        let renju = g.isRenju
        let filter: GomokuAi.MoveFilter? = (renju && color == GomokuGame.black)
            ? { (x: Int, y: Int) -> Bool in
                !GomokuGame.isForbiddenPoint(snapshot, size: size, x: x, y: y)
            }
            : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let mv = GomokuAi.choose(board: snapshot, size: size, me: color, level: 4, filter: filter)
            DispatchQueue.main.async {
                self.hintWorking = false
                guard self.hub.state == .playing, self.hub.moveNo == moveNo else { return }
                guard let mv else { return }
                self.hint = GoPoint(x: mv.x, y: mv.y)
                self.hintMoveNo = moveNo
            }
        }
    }

    private func saveRecord() {
        guard let g = hub.gomokuGame, !g.history.isEmpty else { return }
        do {
            let me = hub.myColor
            let mine = "我（\(hub.myColorName())）"
            let blackName = me == GomokuGame.black ? mine : hub.opponentName
            let whiteName = me == GomokuGame.white ? mine : hub.opponentName
            var result = hub.resultCode
            if result.isEmpty {
                if g.winner == GomokuGame.black {
                    result = "B+5"
                } else if g.winner == GomokuGame.white {
                    result = "W+5"
                }
            }
            let url = try GomokuRecord.saveToFile(g, blackName: blackName, whiteName: whiteName,
                                                  result: result.isEmpty ? nil : result,
                                                  directory: GomokuGameModel.recordsDirectory)
            shareItem = ShareItem(url: url, title: "棋谱已保存")
        } catch {
            saveFailure = error.localizedDescription
            prompt = .saveFailed
        }
    }

    // MARK: - 结果

    private var resultOverlay: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("对局结束")
                    .font(.system(size: 12))
                    .tracking(3)
                    .foregroundColor(theme.foot)
                Text(hub.resultText)
                    .font(.qySerif(21, weight: .bold))
                    .foregroundColor(theme.title)
                    .multilineTextAlignment(.center)
                if !hub.resultDetail.isEmpty {
                    Text(hub.resultDetail)
                        .font(.system(size: 13))
                        .foregroundColor(theme.sub)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                ThemedActionButton(title: "离开房间", kind: .primary, theme: theme) { leave() }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: theme.isHara ? 6 : 20)
                    .fill(theme.windowBg)
            )
            .padding(.horizontal, 34)
        }
    }

    private func leave() {
        hub.stop()
        dismiss()
    }
}
