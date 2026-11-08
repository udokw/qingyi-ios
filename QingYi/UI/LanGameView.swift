import SwiftUI

/// 联机对局页：复用本地棋盘视图，客机执后手时整体旋转 180°。
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

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    topBar
                    if hub.linkDown && hub.state == .playing { linkBanner }
                    boardArea
                    clockRow
                    moveLine
                    if !hub.notice.isEmpty {
                        Text(hub.notice)
                            .font(.system(size: 12))
                            .foregroundColor(theme.sub)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                    controls
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }

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
        hints = g.legalMoves(from: GoPoint(x: x, y: y)).map { $0.to }
    }

    private func clearSelection() {
        selection = nil
        hints = []
    }

    private func flashTurn() {
        // 走子节奏由 Hub 统一提示，这里只清掉旧选中
        clearSelection()
    }

    // MARK: - 时钟 / 上一手

    private var clockRow: some View {
        HStack(spacing: 12) {
            clockPill(seat: 1, mine: hub.myColor == 1)
            clockPill(seat: 2, mine: hub.myColor == 2)
        }
    }

    private func clockPill(seat: Int, mine: Bool) -> some View {
        let active = hub.turn == seat && hub.state == .playing
        return VStack(spacing: 2) {
            Text(mine ? "我方" : "对手")
                .font(.system(size: 11))
                .foregroundColor(theme.foot)
            Text(hub.clockLabel(seat: seat))
                .font(.system(size: 15, weight: active ? .semibold : .regular, design: .monospaced))
                .foregroundColor(active ? theme.accent : theme.title)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: theme.isHara ? 2 : 12)
                .fill(theme.isHara ? Color.clear : theme.btnBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.isHara ? 2 : 12)
                .stroke(active ? theme.accent.opacity(0.7) : (theme.isHara ? theme.divider : Color.clear),
                        lineWidth: 0.8)
        )
    }

    private var moveLine: some View {
        HStack(spacing: 8) {
            Text("第 \(hub.moveNo) 手")
                .font(.system(size: 12))
                .foregroundColor(theme.foot)
            if !hub.lastMoveText.isEmpty {
                Text(hub.lastMoveText)
                    .font(.system(size: 13))
                    .foregroundColor(theme.sub)
            }
            Spacer(minLength: 0)
            Text(hub.state == .playing ? (hub.isMyTurn ? "轮到你走" : "等待对手") : "")
                .font(.system(size: 12))
                .foregroundColor(hub.isMyTurn ? theme.accent : theme.sub)
        }
    }

    // MARK: - 操作

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if game == .go {
                    ThemedActionButton(title: "停一手", theme: theme) {
                        _ = hub.requestPass()
                    }
                }
                ThemedActionButton(title: "悔棋", theme: theme) {
                    hub.requestUndo()
                }
                ThemedActionButton(title: "认输", kind: .danger, theme: theme) {
                    prompt = .resign
                }
            }
            HStack(spacing: 10) {
                if game == .go, hub.isHost {
                    ThemedActionButton(title: "数子", theme: theme) {
                        hub.requestScore()
                    }
                }
                ThemedActionButton(title: "离开", kind: .danger, theme: theme) {
                    prompt = .leave
                }
            }
        }
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
