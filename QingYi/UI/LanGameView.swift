import SwiftUI

/// 联机对局页。
///
/// 版式以用户提供的效果图为唯一基准（效果图为墨白主题），自上而下：
/// 三列页头（我执X / 棋种·房号+对手 / 当前状态 + 朱红「联」徽章）
/// → 规则行 → 发丝线 → 时钟行（黑左白右，中间竖线）
/// → 近满宽棋盘 → 棋盘下一行状态 → 2 行 × 3 列通栏动作区 → 页脚。
/// 颜色、描边、圆角全部取自 Theme（墨白 / 粉彩），不另起一套配色。
struct LanGameView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hub = LanHub.shared
    let game: GameKind

    @State private var selection: GoPoint?
    @State private var hints: [GoPoint] = []
    @State private var prompt: GamePrompt?
    @State private var shareItem: ShareItem?
    @State private var saveFailure = ""

    private var theme: Theme { app.theme }
    private var flipped: Bool { hub.myColor == 2 }
    /// 粉彩主题没有 divider 色，沿用它的 dlgLine 作为发丝线颜色
    private var lineColor: Color { theme.isHara ? theme.divider : theme.dlgLine }

    private enum GamePrompt: Int, Identifiable {
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
        ZStack {
            PaperBackground(theme: theme)

            VStack(spacing: 0) {
                headerRow
                    .padding(.horizontal, 6)
                    .padding(.top, 2)

                ruleRow
                    .padding(.horizontal, 6)
                    .padding(.top, 10)

                Hairline(color: lineColor)
                    .padding(.top, 8)

                clockRow
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                boardArea
                    .padding(.horizontal, 6)
                    .padding(.top, 4)

                stateLine
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                if hub.linkDown && hub.state == .playing {
                    Text("连接中断，正在重连…（计时已暂停，\(LanProto.reconnectGraceMs / 1000) 秒内未恢复将判负）")
                        .font(.system(size: 11))
                        .foregroundColor(theme.dangerText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }

                Spacer(minLength: 8)

                controls

                footer
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
            .padding(.top, 4)

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
            // 联机对局之前完全没有初始化音效开关，导致双方都听不到落子声
            if game == .xiangqi { SoundPlayer.shared.setEnabled(true) }
        }
    }

    // MARK: - 页头（三列 + 朱红「联」）

    private var headerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text("我执\(hub.myColorName())")
                .font(.system(size: 17))
                .foregroundColor(theme.title)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 4)

            VStack(spacing: 2) {
                Text("\(LanProto.gameName(gameIdText)) · 房号 \(hub.roomCode)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(theme.title)
                    .lineLimit(1)
                Text("我执\(hub.myColorName()) · 对手 \(hub.opponentName)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.sub)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            // 效果图里「联」徽章在右上角单独一行，状态文字在它下面
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
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
        }
    }

    private var gameIdText: String { hub.gameId.isEmpty ? (game == .go ? LanProto.goGame : LanProto.xiangqiGame) : hub.gameId }

    private var statusText: String {
        if hub.state == .finished { return "对局结束" }
        if hub.state != .playing { return "等待连接…" }
        if hub.linkDown { return "重连中…" }
        if hub.scorePending { return hub.isHost ? "点「确认数子」" : "等待房主确认" }
        if hub.isMyTurn { return hub.pendingMove ? "已发送 · 等待确认" : "轮到你落子" }
        return "等待对手落子"
    }

    // MARK: - 规则行

    private var ruleRow: some View {
        Text(ruleText)
            .font(.system(size: 12))
            .foregroundColor(theme.sub)
            .frame(maxWidth: .infinity, alignment: .center)
            .lineLimit(1)
    }

    private var ruleText: String {
        if game == .go {
            let komi = hub.komi == floor(hub.komi) ? String(Int(hub.komi)) : String(hub.komi)
            return "\(hub.boardSize) 路 · 中国规则 · 贴 \(komi) 目 · \(hub.timerEnabled ? "计时" : "不计时")"
        }
        return "9 × 10 · 中国象棋 · \(hub.timerEnabled ? "计时" : "不计时")"
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

    // MARK: - 棋盘下一行（原来在通知区的信息合并到这里）

    private var stateLine: some View {
        Text(stateLineText)
            .font(.system(size: 12))
            .foregroundColor(theme.sub)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var stateLineText: String {
        if !hub.notice.isEmpty { return hub.notice }
        if hub.state != .playing { return hub.state == .finished ? "对局已结束" : "等待对手加入…" }
        if hub.moveNo == 0 {
            return game == .go ? "开局 · 黑先" : "开局 · 红先"
        }
        let pass = hub.lastMoveText.isEmpty ? "" : " · \(hub.lastMoveText)"
        return "第 \(hub.moveNo) 手\(pass)"
    }

    // MARK: - 动作区（通栏 3 列 × 2 行，发丝线分隔）

    private var actionItems: [ActionItem] {
        var items: [ActionItem] = []
        items.append(ActionItem(id: 0, title: "悔棋", en: "UNDO", danger: false, primary: false) {
            hub.requestUndo()
        })
        if game == .go {
            items.append(ActionItem(id: 1, title: "停一手", en: "PASS", danger: false, primary: false) {
                _ = hub.requestPass()
            })
        }
        items.append(ActionItem(id: 2, title: "认输", en: "RESIGN", danger: true, primary: false) {
            prompt = .resign
        })
        if game == .go && hub.isHost {
            let confirming = hub.scorePending
            items.append(ActionItem(id: 3, title: confirming ? "确认数子" : "数子",
                                    en: "",
                                    danger: false, primary: confirming) {
                if confirming { hub.confirmScore() } else { hub.requestScore() }
            })
        }
        if game == .go {
            items.append(ActionItem(id: 5, title: "存谱", en: "SAVE SGF", danger: false, primary: false) {
                saveSgf()
            })
        }
        items.append(ActionItem(id: 4, title: "离开", en: "LEAVE", danger: false, primary: false) {
            prompt = .leave
        })
        return items
    }

    /// 与单机页同一个存谱通路：写 Documents/清弈/*.sgf 后弹系统分享面板。
    private func saveSgf() {
        guard let g = hub.goGame, !g.history.isEmpty else { return }
        do {
            let url = try Sgf.saveToDocuments(g, blackName: "黑方", whiteName: "白方",
                                              result: hub.state == .finished ? hub.resultText : nil)
            shareItem = ShareItem(url: url, title: "棋谱已保存")
        } catch {
            saveFailure = error.localizedDescription
            prompt = .saveFailed
        }
    }

    /// 快照动作，避免在 ViewBuilder 里做可变捕获
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
                        gridCell(item)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                Hairline(color: lineColor)
            }
        }
    }

    private func gridCell(_ item: ActionItem) -> some View {
        Button(action: item.run) {
            VStack(spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: item.primary ? .semibold : .regular))
                    .foregroundColor(item.danger ? theme.dangerText
                                     : (item.primary ? theme.accent : theme.title))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !item.en.isEmpty {
                    Text(item.en)
                        .font(.system(size: 9))
                        .tracking(0.8)
                        .foregroundColor(theme.sub)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 页脚

    private var footer: some View {
        Text("局 域 网 · 清 弈")
            .font(.system(size: 11))
            .tracking(2.6)
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
