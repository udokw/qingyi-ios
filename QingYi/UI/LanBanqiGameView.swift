import SwiftUI

/// 联机暗棋：横屏、棋盘铺满长边；翻子与走子都发给房主裁决。
/// 暗子身份只由房主掌握，客户端只知道已翻开的子。
struct LanBanqiGameView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var hub = LanHub.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selection: GoPoint?
    @State private var legalTargets: [GoPoint] = []
    @State private var showPanel = false
    @State private var prompt: Prompt?
    private var theme: Theme { app.theme }
    private var flipped: Bool { hub.myColor == BanqiGame.seatSecond }

    private enum Prompt: Int, Identifiable {
        case resign, leave
        var id: Int { rawValue }
    }

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)

            BanqiBoardView(board: codes,
                           faceUp: faceUp,
                           selection: selection,
                           legalTargets: legalTargets,
                           flipped: flipped,
                           theme: theme,
                           interactive: canAct) { x, y in
                tap(x, y)
            } onLongPress: {
                withAnimation(.easeOut(duration: 0.16)) { showPanel = true }
            }
            .ignoresSafeArea()

            hud
            moreButton

            if showPanel {
                Color(hex: 0x181410).opacity(0.36)
                    .ignoresSafeArea()
                    .onTapGesture { closePanel() }
                    .transition(.opacity)
                panel.transition(.move(edge: .trailing))
            }

            if hub.state == .finished { resultOverlay }
        }
        .onAppear {
            SoundPlayer.shared.setEnabled(app.goSound)
            AppDelegate.orientationLock = .landscape
            BanqiOrientation.apply(landscape: true)
        }
        .onDisappear {
            AppDelegate.orientationLock = .portrait
            BanqiOrientation.apply(landscape: false)
        }
        .onChange(of: hub.turn) { _ in clearSelection() }
        .alert(item: $prompt) { item in
            switch item {
            case .resign:
                return Alert(title: Text("认输"),
                             message: Text("确认认输？本局将判负。"),
                             primaryButton: .destructive(Text("认输")) { hub.resign() },
                             secondaryButton: .cancel(Text("再想想")))
            case .leave:
                return Alert(title: Text("离开对局"),
                             message: Text("对局尚未结束，离开将中断连接。"),
                             primaryButton: .destructive(Text("离开")) {
                                 hub.stop()
                                 dismiss()
                             },
                             secondaryButton: .cancel(Text("留下")))
            }
        }
    }

    // MARK: - 数据

    private var canAct: Bool {
        hub.state == .playing && hub.isMyTurn && !hub.pendingMove && !hub.linkDown
    }

    private var codes: [[Int]] {
        guard let g = hub.banqiGame else {
            return Array(repeating: Array(repeating: BanqiGame.hidden,
                                          count: BanqiGame.cols), count: BanqiGame.rows)
        }
        return g.boardCodes
    }

    private var faceUp: [[Bool]] {
        guard let g = hub.banqiGame else {
            return Array(repeating: Array(repeating: false,
                                          count: BanqiGame.cols), count: BanqiGame.rows)
        }
        return g.faceUpGrid
    }

    /// 与 Android LanBanqiActivity 一致：「● 阶段 · 红方行棋」。
    private var turnText: String {
        let phase: String
        if hub.state == .finished {
            phase = "对局结束"
        } else if hub.state != .playing {
            phase = "等待连接"
        } else if hub.linkDown {
            phase = "重连中"
        } else if !hub.isMyTurn {
            phase = "等待对手"
        } else {
            phase = hub.pendingMove ? "已发送" : "轮到你"
        }
        guard hub.state == .playing, !hub.linkDown, let g = hub.banqiGame else {
            return "● \(phase)"
        }
        let colorPart: String
        switch g.turnColor {
        case BanqiGame.red: colorPart = "红方行棋"
        case BanqiGame.black: colorPart = "黑方行棋"
        default: colorPart = g.turnSeat == BanqiGame.seatFirst ? "先手行棋" : "后手行棋"
        }
        return "● \(phase) · \(colorPart)"
    }

    private var countText: String {
        var red = 0, black = 0, hidden = 0
        let b = codes
        let f = faceUp
        for y in 0..<BanqiGame.rows {
            for x in 0..<BanqiGame.cols {
                let p = b[y][x]
                if p == BanqiGame.empty { continue }
                if !f[y][x] { hidden += 1; continue }
                if BanqiGame.colorOf(p) == BanqiGame.red { red += 1 } else { black += 1 }
            }
        }
        return "红 \(red) · 黑 \(black) · 暗 \(hidden)"
    }

    // MARK: - 交互

    private func tap(_ x: Int, _ y: Int) {
        guard canAct, let g = hub.banqiGame else { return }
        let p = g.pieceCodeAt(x, y)
        let up = g.isFaceUp(x, y)

        if p != BanqiGame.empty, up, BanqiGame.colorOf(p) == g.turnColor {
            if selection?.x == x && selection?.y == y {
                clearSelection()
            } else {
                selection = GoPoint(x: x, y: y)
                legalTargets = g.legalMovesFrom(x, y).map { GoPoint(x: $0.tx, y: $0.ty) }
            }
            return
        }

        if let sel = selection {
            _ = hub.requestBanqiMove(flip: false, fx: sel.x, fy: sel.y, tx: x, ty: y)
            clearSelection()
            return
        }

        if p == BanqiGame.hidden || (p != BanqiGame.empty && !up) {
            _ = hub.requestBanqiMove(flip: true, x: x, y: y)
        }
    }

    private func clearSelection() {
        selection = nil
        legalTargets = []
    }

    // MARK: - 常驻 HUD

    private var hud: some View {
        VStack {
            HStack(spacing: 8) {
                Text(turnText)
                    .font(.system(size: 13))
                    .tracking(1.3)
                    .foregroundColor(Color(hex: 0x1A1A1A))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(countText)
                    .font(.system(size: 11.5))
                    .tracking(0.5)
                    .foregroundColor(Color(hex: 0x6B665C))
                    .lineLimit(1)
            }
            .padding(.horizontal, 42)
            .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    private var moreButton: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showPanel = true }
                } label: {
                    Text("⋯")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: 0x8A8474))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 24)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - 操作浮层

    private var panel: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("操 作")
                        .font(.system(size: 11.5))
                        .tracking(3.2)
                        .foregroundColor(Color(hex: 0x6B665C))
                    Spacer(minLength: 8)
                    Button { closePanel() } label: {
                        Text("✕")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: 0x6B665C))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .frame(height: 52)

                divider
                row("悔棋") {
                    closePanel()
                    hub.requestUndo()
                }
                divider
                row("认输", danger: true) {
                    closePanel()
                    prompt = .resign
                }
                divider
                roomRow
                divider
                row("返回主页", danger: true) {
                    closePanel()
                    prompt = .leave
                }
                Spacer(minLength: 0)
            }
            .frame(width: 252)
            .background(PaperBackground(theme: theme))
            .padding(.vertical, 12)
            .padding(.trailing, 12)
        }
        .ignoresSafeArea()
    }

    private var divider: some View {
        Rectangle().fill(Color(hex: 0xDDD6C4)).frame(height: 1)
    }

    private func row(_ title: String, danger: Bool = false,
                     _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(danger ? Color(hex: 0xC73E2B) : Color(hex: 0x1A1A1A))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 面板里的房间号：只展示，不可点（与 Android 同一行）。
    private var roomRow: some View {
        HStack(spacing: 8) {
            Text("房间号")
                .font(.system(size: 15))
                .foregroundColor(Color(hex: 0x1A1A1A))
            Spacer(minLength: 8)
            Text(hub.roomCode.isEmpty ? "—" : hub.roomCode)
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: 0x6B665C))
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
    }

    private func closePanel() {
        withAnimation(.easeOut(duration: 0.16)) { showPanel = false }
    }

    private var resultOverlay: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 10) {
                Text("对局结束")
                    .font(.system(size: 12))
                    .tracking(3)
                    .foregroundColor(theme.foot)
                Text(hub.resultText)
                    .font(.qySerif(20, weight: .bold))
                    .foregroundColor(theme.title)
                    .multilineTextAlignment(.center)
                if !hub.resultDetail.isEmpty {
                    Text(hub.resultDetail)
                        .font(.system(size: 12))
                        .foregroundColor(theme.sub)
                        .multilineTextAlignment(.center)
                }
                ThemedActionButton(title: "离开房间", kind: .primary, theme: theme) {
                    hub.stop()
                    dismiss()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: theme.isHara ? 6 : 18)
                    .fill(theme.windowBg)
            )
            .padding(.horizontal, 80)
        }
    }
}
