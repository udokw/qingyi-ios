import SwiftUI

/// 联机对局页：棋盘尺寸、页面占比与底部按钮统一比照单机对局页
/// （GoGameView / XiangqiGameView），不再另起一套视觉。
struct LanGameView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hub = LanHub.shared
    let game: GameKind

    @State private var selection: GoPoint?
    @State private var hints: [GoPoint] = []
    @State private var prompt: GamePrompt?

    private var theme: Theme { app.theme }
    private var flipped: Bool { hub.myColor == 2 }

    private enum GamePrompt: Int, Identifiable {
        case resign, leave
        var id: Int { rawValue }
    }

    /// 底部动作项：与单机页同一套按钮语义（normal / primary / danger）
    private struct ActionItem {
        let title: String
        let en: String
        let kind: ActionKind
        let run: () -> Void
    }

    private struct ActionRow: Identifiable {
        let id: Int
        let items: [ActionItem]
    }

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)

            VStack(spacing: 0) {
                topBar

                if hub.linkDown && hub.state == .playing {
                    linkBanner.padding(.top, 6)
                }

                Spacer(minLength: 8)

                boardArea
                    .padding(.top, game == .go ? 10 : 8)

                infoBlock
                    .padding(.top, 10)

                if !theme.isHara {
                    if game == .go {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(hex: 0xD8C9B8))
                            .frame(width: 140, height: 10)
                            .padding(.top, 8)
                        Text("安 静 的 一 手")
                            .font(.system(size: 11))
                            .tracking(3.3)
                            .foregroundColor(theme.foot)
                            .padding(.top, 16)
                    } else {
                        Text("楚 河 汉 界 · 一 局 清 弈")
                            .font(.system(size: 11))
                            .tracking(3.3)
                            .foregroundColor(theme.foot)
                            .padding(.top, 6)
                    }
                }

                controls
                    .padding(.top, game == .go ? 40 : (theme.isHara ? 22 : 40))

                if theme.isHara {
                    signature.padding(.top, game == .go ? 24 : 20)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 14)

            if hub.state == .finished {
                resultOverlay
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
                return Alert(title: Text("离开房间？"),
                             message: Text("离开后本局结束，无法继续下棋。"),
                             primaryButton: .destructive(Text("离开")) { leave() },
                             secondaryButton: .cancel(Text("留在房间")))
            }
        }
        .onAppear {
            // 联机对局之前完全没有初始化音效开关，导致双方都听不到落子声
            if game == .xiangqi { SoundPlayer.shared.setEnabled(true) }
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(LanProto.gameName(hub.gameId)) · 房号 \(hub.roomCode)")
                    .font(.qySerif(16, weight: .bold))
                    .foregroundColor(theme.title)
                Text("我执\(hub.myColorName()) · 对手 \(hub.opponentName)")
                    .font(.system(size: 12))
                    .foregroundColor(theme.sub)
            }
            Spacer(minLength: 0)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundColor(hub.linkDown && hub.state == .playing ? theme.dangerText : theme.foot)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.isHara ? 2 : 10)
                        .stroke(hub.linkDown && hub.state == .playing ? theme.dangerStroke : theme.divider, lineWidth: 0.8)
                )
        }
        .padding(.top, 4)
    }

    private var statusText: String {
        if hub.state == .finished { return "已结束" }
        return hub.linkDown ? "重连中" : "在线"
    }

    private var linkBanner: some View {
        Text("连接中断，正在重连…（计时已暂停，\(LanProto.reconnectGraceMs / 1000) 秒内未恢复将判负）")
            .font(.system(size: 12))
            .foregroundColor(theme.dangerText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: theme.isHara ? 2 : 10)
                    .fill(theme.isHara ? Color.clear : theme.btnBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.isHara ? 2 : 10)
                    .stroke(theme.dangerStroke, lineWidth: 0.8)
            )
    }

    // MARK: - 棋盘

    @ViewBuilder
    private var boardArea: some View {
        Group {
            if game == .go {
                GoBoardView(board: hub.goBoard,
                            size: hub.boardSize,
                            lastMove: hub.lastMoveGo,
                            ko: hub.koPoint,
                            territory: nil,
                            theme: theme) { x, y in
                    _ = hub.requestMove(x: x, y: y)
                }
            } else {
                XiangqiBoardView(board: hub.xiangqiBoard,
                                 selection: selection,
                                 hints: hints,
                                 lastMove: hub.lastMoveXiangqi,
                                 theme: theme,
                                 onTap: { x, y in tapXiangqi(x, y) },
                                 onDrag: { fx, fy, tx, ty in dragXiangqi(fx, fy, tx, ty) },
                                 flipped: flipped)
            }
        }
        // 象棋不再靠父级旋转翻转（会连带把棋盘文字转倒），
        // 改由 XiangqiBoardView 内部按坐标镜像翻转，文字天然正立。
        // 围棋棋盘没有文字，仍用整盘旋转。
        .rotationEffect(.degrees(game == .go && flipped ? 180 : 0))
        .animation(.easeInOut(duration: 0.2), value: flipped)
    }

    private func tapXiangqi(_ x: Int, _ y: Int) {
        guard hub.state == .playing, let g = hub.xiangqiGame else { return }
        guard hub.isMyTurn else {
            flashTurn()
            return
        }
        let turn = g.turn
        let tapped = g.piece(at: x, y)
        if let from = selection {
            if let piece = tapped, piece.color == turn {
                select(x, y)
                return
            }
            _ = hub.requestXiangqiMove(fx: from.x, fy: from.y, tx: x, ty: y)
            clearSelection()
            return
        }
        if let piece = tapped, piece.color == turn {
            select(x, y)
        }
    }

    private func dragXiangqi(_ fx: Int, _ fy: Int, _ tx: Int, _ ty: Int) {
        guard hub.state == .playing, let g = hub.xiangqiGame, hub.isMyTurn else { return }
        guard let piece = g.piece(at: fx, fy), piece.color == g.turn else {
            tapXiangqi(tx, ty)
            return
        }
        if !hub.requestXiangqiMove(fx: fx, fy: fy, tx: tx, ty: ty) {
            select(fx, fy)
        } else {
            clearSelection()
        }
    }

    private func select(_ x: Int, _ y: Int) {
        guard let g = hub.xiangqiGame else { return }
        selection = GoPoint(x: x, y: y)
        // 是否显示落点提示由房主的房间规则决定，客机不自行决定
        hints = hub.hintsEnabled
            ? g.legalMoves(from: GoPoint(x: x, y: y)).map { $0.to }
            : []
    }

    private func clearSelection() {
        selection = nil
        hints = []
    }

    private func flashTurn() {
        // 走子节奏由 Hub 统一提示，这里只清掉旧选中
        clearSelection()
    }

    // MARK: - 时钟 / 上一手 / 提示

    private var infoBlock: some View {
        VStack(spacing: 6) {
            clockRow
            moveLine
            if !hub.notice.isEmpty {
                Text(hub.notice)
                    .font(.system(size: 12))
                    .foregroundColor(theme.sub)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var clockRow: some View {
        HStack(spacing: 12) {
            clockPill(seat: 1, mine: hub.myColor == 1)
            clockPill(seat: 2, mine: hub.myColor == 2)
        }
    }

    private func clockPill(seat: Int, mine: Bool) -> some View {
        let active = hub.turn == seat && hub.state == .playing
        return VStack(spacing: 1) {
            Text(mine ? "我方" : "对手")
                .font(.system(size: 10))
                .foregroundColor(theme.foot)
            Text(hub.clockLabel(seat: seat))
                .font(.system(size: 13, weight: active ? .semibold : .regular, design: .monospaced))
                .foregroundColor(active ? theme.accent : theme.title)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: theme.isHara ? 2 : 10)
                .fill(theme.isHara ? Color.clear : theme.btnBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.isHara ? 2 : 10)
                .stroke(active ? theme.accent.opacity(0.7) : (theme.isHara ? theme.divider : Color.clear),
                        lineWidth: 0.8)
        )
    }

    private var moveLine: some View {
        let turnHint = hub.state == .playing ? (hub.isMyTurn ? "轮到你走" : "等待对手走子") : ""
        let movePart = hub.lastMoveText.isEmpty ? "" : "第 \(hub.moveNo) 手 · \(hub.lastMoveText)"
        let text = [turnHint, movePart].filter { !$0.isEmpty }.joined(separator: " · ")
        return Text(text)
            .font(.system(size: 13))
            .foregroundColor(hub.isMyTurn && hub.state == .playing ? theme.accent : theme.sub)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 操作（与单机页同一套按钮 / 栅格）

    private var actionItems: [ActionItem] {
        var items: [ActionItem] = []
        items.append(ActionItem(title: "悔棋", en: "UNDO", kind: .normal) { hub.requestUndo() })
        if game == .go {
            items.append(ActionItem(title: "停一手", en: "PASS", kind: .normal) { _ = hub.requestPass() })
        }
        items.append(ActionItem(title: "认输", en: "RESIGN", kind: .danger) { prompt = .resign })
        if game == .go && hub.isHost {
            if hub.scorePending {
                items.append(ActionItem(title: "确认数子", en: "CONFIRM", kind: .primary) { hub.confirmScore() })
            } else {
                items.append(ActionItem(title: "数子", en: "COUNT", kind: .normal) { hub.requestScore() })
            }
        }
        items.append(ActionItem(title: "离开", en: "LEAVE", kind: .normal) { prompt = .leave })
        return items
    }

    private var actionRows: [ActionRow] {
        let items = actionItems
        var rows: [ActionRow] = []
        var index = 0
        while index < items.count {
            let end = min(index + 3, items.count)
            rows.append(ActionRow(id: rows.count, items: Array(items[index..<end])))
            index = end
        }
        return rows
    }

    @ViewBuilder
    private var controls: some View {
        if theme.isHara {
            VStack(spacing: 0) {
                Hairline(color: theme.divider)
                ForEach(actionRows) { row in
                    HStack(spacing: 0) {
                        ForEach(row.items.indices, id: \.self) { i in
                            Group {
                                if i > 0 { verticalDivider }
                                gridButton(row.items[i])
                            }
                        }
                    }
                    .frame(height: 56)
                    Hairline(color: theme.divider)
                }
            }
        } else {
            VStack(spacing: 12) {
                ForEach(actionRows) { row in
                    HStack(spacing: 12) {
                        ForEach(row.items.indices, id: \.self) { i in
                            pill(row.items[i])
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(width: 0.6)
    }

    private func gridButton(_ item: ActionItem) -> some View {
        Button(action: item.run) {
            VStack(spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15))
                    .foregroundColor(item.kind == .danger ? theme.dangerText
                                     : (item.kind == .primary ? theme.primaryText : theme.title))
                Text(item.en)
                    .font(.system(size: 9))
                    .tracking(1)
                    .foregroundColor(item.kind == .primary ? theme.primaryText.opacity(0.7) : theme.sub)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(item.kind == .primary ? theme.primaryBg : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ item: ActionItem) -> some View {
        Button(action: item.run) {
            Text(item.title)
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundColor(item.kind == .primary ? theme.primaryText
                                 : (item.kind == .danger ? theme.dangerText : theme.btnText))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: theme.btnRadius)
                        .fill(item.kind == .primary ? theme.primaryBg
                              : (item.kind == .danger ? theme.entryBg[0] : theme.btnBg))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部签字

    private var signature: some View {
        Text(game == .go ? "清 弈 引 擎 · 围 棋" : "清 弈 引 擎 · 象 棋")
            .font(.system(size: 11))
            .tracking(2.75)
            .foregroundColor(theme.foot)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 结果

    private var resultOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
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
                ThemedActionButton(title: "离开房间", kind: .primary, theme: theme) {
                    leave()
                }
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
