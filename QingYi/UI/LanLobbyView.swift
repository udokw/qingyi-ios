import SwiftUI

extension GameKind: Identifiable {
    var id: String { rawValue }
}

/// 联机大厅：创建房间 / 加入房间 / 附近房间 / 手动 IP。
/// 对局开始后由同一个视图切换成棋盘页，保证 LanHub 状态不被打断。
struct LanLobbyView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var hub = LanHub.shared
    let game: GameKind

    @State private var name = ""
    @State private var joinCode = ""
    @State private var manual = ""
    @State private var hostColor = 1
    @State private var timed = true
    @State private var hints = true
    @State private var localError = ""
    @State private var selfTestBusy = false
    @State private var selfTestReport = ""

    private var theme: Theme { app.theme }
    private var gameId: String { game == .go ? LanProto.goGame : LanProto.xiangqiGame }

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)

            if hub.state == .playing || hub.state == .finished {
                LanGameView(game: game)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if hub.state == .idle {
                            createPanel
                            joinPanel
                        } else {
                            roomPanel
                        }
                        if !hub.notice.isEmpty {
                            Text(hub.notice)
                                .font(.system(size: 13))
                                .foregroundColor(theme.sub)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                }
            }
        }
        .onAppear {
            if name.isEmpty { name = hub.localName }
            hub.startBrowsing(game: gameId)
        }
        .onDisappear { hub.stopBrowsing() }
        .onChange(of: hub.state) { value in
            if value == .playing || value == .finished {
                hub.stopBrowsing()
                localError = ""
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: hub.appMovedToBackground()
            case .active: hub.appMovedToForeground()
            default: break
            }
        }
        .alert("悔棋请求", isPresented: undoAlertBinding) {
            Button("接受") { hub.respondUndo(accept: true) }
            Button("拒绝", role: .cancel) { hub.respondUndo(accept: false) }
        } message: {
            Text("\(hub.opponentName) 请求悔棋")
        }
    }

    private var undoAlertBinding: Binding<Bool> {
        Binding(
            get: { hub.incomingUndoFrom != nil },
            set: { if !$0 { hub.respondUndo(accept: false) } }
        )
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                leave()
            } label: {
                Text("‹ 返回")
                    .font(.system(size: 15))
                    .foregroundColor(theme.sub)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text("联机对弈 · \(LanProto.gameName(gameId))")
                .font(.qySerif(17, weight: .bold))
                .foregroundColor(theme.title)
        }
        .padding(.top, 8)
    }

    // MARK: - 创建

    private var createPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("创建房间")
            field("你的称呼", text: $name, keyboard: .default)
            HStack(spacing: 22) {
                CheckRow(title: colorOptionTitle(1), checked: hostColor == 1, theme: theme) { hostColor = 1 }
                CheckRow(title: colorOptionTitle(2), checked: hostColor == 2, theme: theme) { hostColor = 2 }
            }
            CheckRow(title: "20 分钟 + 读秒 30 秒 × 3", checked: timed, theme: theme) { timed = true }
            CheckRow(title: "不计时", checked: !timed, theme: theme) { timed = false }
            if gameId == LanProto.xiangqiGame {
                CheckRow(title: "落点提示与可吃子提示（房间规则）", checked: hints, theme: theme) {
                    hints.toggle()
                }
            }
            ThemedActionButton(title: "创建房间", kind: .primary, theme: theme) {
                localError = ""
                hub.hostRoom(game: gameId, name: name, color: hostColor,
                             mainSec: timed ? 1200 : 0,
                             byoYomiSec: timed ? 30 : 0,
                             periods: timed ? 3 : 0,
                             hints: hints)
            }
            Button {
                runSelfTest()
            } label: {
                Text(selfTestBusy ? "正在逐个测试端口…" : "网络与端口自检")
                    .font(.system(size: 12))
                    .foregroundColor(theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(selfTestBusy)
            if !selfTestReport.isEmpty {
                Text(selfTestReport)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.sub)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(panelBackground)
    }

    private func colorOptionTitle(_ seat: Int) -> String {
        gameId == LanProto.goGame
            ? (seat == 1 ? "执黑先行" : "执白后行")
            : (seat == 1 ? "执红先行" : "执黑后行")
    }

    // MARK: - 加入

    private var joinPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("加入房间")
            field("你的称呼", text: $name, keyboard: .default)
            field("四位房号", text: $joinCode, keyboard: .asciiCapable)
            field("手动地址（如 192.168.1.5:41234）", text: $manual, keyboard: .numbersAndPunctuation)
            Text("只填房号也能加入：留空地址，会自动按房号在同一网络内查询。")
                .font(.system(size: 11))
                .foregroundColor(theme.foot)
            if !localError.isEmpty {
                Text(localError)
                    .font(.system(size: 12))
                    .foregroundColor(theme.dangerText)
            }
            ThemedActionButton(title: "加入", kind: .normal, theme: theme) { joinByInput() }

            Hairline(color: theme.divider)
                .padding(.vertical, 2)

            HStack {
                Text("附近房间")
                    .font(.qySerif(15, weight: .bold))
                    .foregroundColor(theme.title)
                Spacer(minLength: 0)
                Text("\(hub.rooms.count) 个")
                    .font(.system(size: 12))
                    .foregroundColor(theme.foot)
            }

            if hub.rooms.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("正在搜索同一网络内的房间…")
                        .font(.system(size: 13))
                        .foregroundColor(theme.sub)
                    Text("搜不到时：① 确认两台设备连同一个 Wi-Fi；② 关闭手机上的 VPN / 代理（会挡住 mDNS 组播）；③ 直接在上面填四位房号即可加入——不需要填 IP，会自动用 UDP 广播按房号找房主。")
                        .font(.system(size: 11))
                        .foregroundColor(theme.foot)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(hub.rooms) { room in
                        roomRow(room)
                        if room.id != hub.rooms.last?.id {
                            Hairline(color: theme.divider)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(panelBackground)
    }

    private func roomRow(_ room: LanRoom) -> some View {
        Button {
            localError = ""
            hub.joinRoom(room: room, name: name)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("房号 \(room.code)")
                        .font(.qySerif(16, weight: .bold))
                        .foregroundColor(theme.entryTitle)
                    Text("\(room.gameLabel) · \(room.boardText) · \(room.verified ? "可加入" : "正在确认房主…")")
                        .font(.system(size: 12))
                        .foregroundColor(theme.entryDesc)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("加入")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accent)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func joinByInput() {
        let code = LanProto.normalizeRoomCode(joinCode)
        guard code.count == 4 else {
            localError = "请输入四位房号"
            return
        }
        localError = ""
        hub.joinByInput(code: code, address: manual, name: name, game: gameId)
    }

    private func runSelfTest() {
        guard !selfTestBusy else { return }
        selfTestBusy = true
        selfTestReport = ""
        Task {
            let report = await LanPortProbe.report()
            await MainActor.run {
                selfTestReport = report
                selfTestBusy = false
            }
        }
    }

    // MARK: - 房间状态

    private var roomPanel: some View {
        VStack(spacing: 16) {
            sectionTitle(roomTitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !hub.roomCode.isEmpty {
                VStack(spacing: 6) {
                    Text("房号")
                        .font(.system(size: 12))
                        .foregroundColor(theme.foot)
                    Text(hub.roomCode)
                        .font(.qySerif(40, weight: .bold))
                        .tracking(8)
                        .foregroundColor(theme.title)
                    if !hub.hostAddress.isEmpty {
                        Text(hub.hostAddress)
                            .font(.system(size: 13))
                            .foregroundColor(theme.sub)
                    }
                    Text(hub.hostAddress.isEmpty ? "" : "同一网络内可手动输入上面的地址")
                        .font(.system(size: 11))
                        .foregroundColor(theme.foot)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            switch hub.state {
            case .connecting:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在连接 \(hub.hostAddress)…")
                        .font(.system(size: 14))
                        .foregroundColor(theme.sub)
                }
            case .error:
                Text(hub.lastError)
                    .font(.system(size: 13))
                    .foregroundColor(theme.dangerText)
                    .multilineTextAlignment(.center)
            case .hosting, .lobby:
                Text(hub.isHost
                     ? (hub.hasGuest ? "对手 \(hub.opponentName) 已加入" : "等待对手加入…")
                     : "已加入房间，等待房主开局…")
                    .font(.system(size: 14))
                    .foregroundColor(theme.sub)
            default:
                EmptyView()
            }

            if hub.isHost, hub.state == .hosting || hub.state == .lobby {
                ThemedActionButton(title: "开始对局", kind: .primary, theme: theme) {
                    hub.startGame()
                }
                .opacity(hub.hasGuest ? 1 : 0.4)
                .disabled(!hub.hasGuest)
            }

            ThemedActionButton(title: hub.state == .error ? "返回" : "取消", kind: .danger, theme: theme) {
                leave()
            }
        }
        .padding(18)
        .background(panelBackground)
    }

    private var roomTitle: String {
        switch hub.state {
        case .hosting, .lobby: return hub.isHost ? "房间已创建" : "等待开局"
        case .connecting: return "正在加入"
        case .error: return "加入失败"
        default: return "联机对弈"
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.qySerif(17, weight: .bold))
            .foregroundColor(theme.title)
            .tracking(1)
    }

    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 15))
            .foregroundColor(theme.title)
            .keyboardType(keyboard)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: theme.isHara ? 2 : 12)
                    .fill(theme.isHara ? Color.clear : theme.windowBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.isHara ? 2 : 12)
                    .stroke(theme.btnStroke, lineWidth: 0.8)
            )
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: theme.isHara ? 2 : 18)
            .fill(theme.isHara ? Color.clear : theme.btnBg)
            .overlay(
                RoundedRectangle(cornerRadius: theme.isHara ? 2 : 18)
                    .stroke(theme.isHara ? theme.divider : Color.clear, lineWidth: 0.8)
            )
    }

    private func leave() {
        hub.stop()
        dismiss()
    }
}
