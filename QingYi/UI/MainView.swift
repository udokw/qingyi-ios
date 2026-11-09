import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var app: AppState
    @State private var goSetup: GoSetup?
    @State private var xqSetup: XiangqiSetup?
    @State private var gomokuSetup: GomokuSetup?
    @State private var banqiSetup: BanqiSetup?
    @State private var showGoConfig = false
    @State private var showXqConfig = false
    @State private var showGomokuConfig = false
    @State private var showLibrary = false
    @State private var lanKind: GameKind?
    @State private var pendingGo: GoSetup?
    @State private var pendingXQ: XiangqiSetup?
    @State private var pendingGMK: GomokuSetup?
    @State private var pendingBQ: BanqiSetup?
    @State private var localDialogKind: GameKind?
    @State private var rulesKind: GameKind?

    private var theme: Theme { app.theme }

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)

            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        themeRow
                        Spacer().frame(height: 12)

                        if theme.isHara {
                            OrnamentRow(theme: theme)
                                .padding(.top, 22)
                        } else {
                            DomeMark()
                                .padding(.top, 20)
                        }

                        titleRow
                            .padding(.top, 12)

                        Text("多引擎 · 围棋、象棋、五子棋与暗棋")
                            .font(.system(size: 14))
                            .tracking(1.7)
                            .foregroundColor(theme.sub)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 10)
                            .padding(.bottom, 18)

                        segmented
                            .padding(.top, theme.isHara ? 71 : 18)
                            .padding(.bottom, 12)

                        entries

                        Spacer(minLength: 30)

                        footer
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
            }

            if showGoConfig {
                GoConfigDialog(theme: theme, defaultSound: app.goSound) { sound, setup in
                    app.goSound = sound
                    SoundPlayer.shared.setEnabled(sound)
                    showGoConfig = false
                    pendingGo = setup
                } onCancel: {
                    showGoConfig = false
                }
                .transition(.opacity)
                .zIndex(3)
            }

            if showXqConfig {
                XiangqiConfigDialog(theme: theme, defaultHints: app.xqHints) { hints, setup in
                    app.xqHints = hints
                    showXqConfig = false
                    pendingXQ = setup
                } onCancel: {
                    showXqConfig = false
                }
                .transition(.opacity)
                .zIndex(3)
            }

            if showGomokuConfig {
                GomokuConfigDialog(theme: theme) { setup in
                    showGomokuConfig = false
                    pendingGMK = setup
                } onCancel: {
                    showGomokuConfig = false
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showGoConfig)
        .animation(.easeInOut(duration: 0.18), value: showXqConfig)
        .animation(.easeInOut(duration: 0.18), value: showGomokuConfig)
        .sheet(isPresented: $showLibrary) {
            LibraryView(theme: theme, kind: app.kind) { url in
                showLibrary = false
                openRecord(url)
            }
        }
        .fullScreenCover(item: $goSetup) { setup in
            GoGameView(setup: setup)
                .environmentObject(app)
                .keepsScreenAwake()
        }
        .fullScreenCover(item: $xqSetup) { setup in
            XiangqiGameView(setup: setup)
                .environmentObject(app)
                .keepsScreenAwake()
        }
        .fullScreenCover(item: $lanKind) { kind in
            LanLobbyView(game: kind)
                .environmentObject(app)
        }
        .fullScreenCover(item: $gomokuSetup) { setup in
            GomokuGameView(setup: setup)
                .environmentObject(app)
                .keepsScreenAwake()
        }
        .fullScreenCover(item: $banqiSetup) { setup in
            BanqiGameView(setup: setup)
                .environmentObject(app)
                .keepsScreenAwake()
        }
        .confirmationDialog("双人对弈", isPresented: Binding(
            get: { localDialogKind != nil },
            set: { if !$0 { localDialogKind = nil } }
        ), titleVisibility: .visible) {
            Button("同机对弈") {
                let kind = localDialogKind
                localDialogKind = nil
                if let kind { startLocal(kind) }
            }
            Button("局域网联机") {
                let kind = localDialogKind
                localDialogKind = nil
                if let kind { lanKind = kind }
            }
            Button("取消", role: .cancel) { localDialogKind = nil }
        }
        .alert(rulesKind == .banqi ? "暗棋 · 玩法说明" : "五子棋 · 玩法说明",
               isPresented: Binding(
                get: { rulesKind != nil },
                set: { if !$0 { rulesKind = nil } }
               )) {
            Button("知道了", role: .cancel) { rulesKind = nil }
        } message: {
            Text(rulesKind == .banqi ? MainView.banqiRules : MainView.gomokuRules)
        }
        .onChange(of: pendingGo) { value in
            guard let value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                goSetup = value
                pendingGo = nil
            }
        }
        .onChange(of: pendingXQ) { value in
            guard let value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                xqSetup = value
                pendingXQ = nil
            }
        }
        .onChange(of: pendingGMK) { value in
            guard let value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                gomokuSetup = value
                pendingGMK = nil
            }
        }
        .onChange(of: pendingBQ) { value in
            guard let value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                banqiSetup = value
                pendingBQ = nil
            }
        }
    }

    private func startLocal(_ kind: GameKind) {
        switch kind {
        case .go: pendingGo = GoSetup(mode: .local)
        case .xiangqi: pendingXQ = XiangqiSetup(mode: .local)
        case .gomoku: pendingGMK = GomokuSetup(mode: .local)
        case .banqi: pendingBQ = BanqiSetup(mode: .local)
        }
    }

    static let gomokuRules = "19 路棋盘，黑先。\n"
        + "横、竖、斜任意方向先连成五子（含五子以上）即胜。\n"
        + "默认无禁手（freestyle），不设三三、四四、长连限制。\n"
        + "可在开局对话框或对局页切换「黑棋禁手」，按连珠规则禁止黑棋长连、四四、三三；白棋无禁手，成五优先判胜。\n"
        + "棋盘下满仍未分胜负为和棋。\n\n"
        + "人机对弈提供五档难度，可开启 AI 落点提示；\n"
        + "本地双人同机轮流；局域网联机由房主统一裁决。"

    static let banqiRules = "4 × 8 棋盘，32 枚棋子全部背朝上，先手先翻。\n"
        + "每回合二选一：翻任意一枚暗子，或走一格己方明子（可吃子）。\n"
        + "首翻定色：先手翻出的颜色归先手，另一方执另一色。\n"
        + "军衔：將 > 士 > 象 > 車 > 馬 > 炮 > 卒，同级可互吃；\n"
        + "卒可吃將，將不能吃卒。\n"
        + "炮走一格空格，吃子必须隔恰好一枚炮架跳吃。\n\n"
        + "无合法步判负；连续 30 步无吃子无翻子判和；\n"
        + "同一局面出现三次判和。联机时暗子身份只由房主裁决。"

    // MARK: - 主题切换（右上角）

    private var themeRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                app.toggleTheme()
            } label: {
                Text("主题 · \(theme.name)")
                    .font(.system(size: 13))
                    .foregroundColor(theme.sub)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - 标题

    private var titleRow: some View {
        HStack(spacing: 10) {
            Text("清弈")
                .font(.qySerif(37, weight: .bold))
                .tracking(theme.isHara ? 1.8 : 6.6)
                .foregroundColor(theme.title)
            if theme.isHara {
                TitleSeal(theme: theme)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 围棋 / 象棋 切换

    private var segmented: some View {
        HStack(spacing: 0) {
            segmentButton(kind: .go, title: "围棋")
            segmentButton(kind: .xiangqi, title: "象棋")
            segmentButton(kind: .gomoku, title: "五子棋")
            segmentButton(kind: .banqi, title: "暗棋")
        }
        .padding(3)
        .frame(height: 40)
        .overlay(
            RoundedRectangle(cornerRadius: theme.isHara ? 2 : 22)
                .stroke(theme.isHara ? theme.divider : theme.dlgLine, lineWidth: 1)
        )
    }

    private func segmentButton(kind: GameKind, title: String) -> some View {
        let selected = app.kind == kind
        return Button {
            app.kind = kind
        } label: {
            Text(title)
                .font(.qySerif(15, weight: .bold))
                .tracking(1.2)
                .foregroundColor(selected ? theme.primaryText : theme.sub)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: theme.isHara ? 2 : 19)
                        .fill(selected ? theme.primaryBg : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 入口

    @ViewBuilder
    private var entries: some View {
        if theme.isHara {
            VStack(spacing: 0) {
                entryRow(0, entryTitle(0), entryDesc(0)) { openEntry(0) }
                Hairline(color: theme.divider)
                entryRow(1, entryTitle(1), entryDesc(1)) { openEntry(1) }
                Hairline(color: theme.divider)
                entryRow(2, entryTitle(2), entryDesc(2)) { openEntry(2) }
            }
        } else {
            VStack(spacing: 17) {
                entryCard(0, entryTitle(0), entryDesc(0), leading: 0, trailing: 24) { openEntry(0) }
                entryCard(1, entryTitle(1), entryDesc(1), leading: 14, trailing: 14) { openEntry(1) }
                entryCard(2, entryTitle(2), entryDesc(2), leading: 24, trailing: 0) { openEntry(2) }
            }
        }
    }

    private func entryTitle(_ index: Int) -> String {
        if index == 0 { return "人机对弈" }
        if index == 1 {
            return app.kind == .go ? "双人对弈" : "本地双人"
        }
        switch app.kind {
        case .go: return "棋谱欣赏"
        case .xiangqi: return "棋谱复盘"
        default: return "玩法说明"
        }
    }

    private func entryDesc(_ index: Int) -> String {
        if index == 0 {
            switch app.kind {
            case .go: return "内置引擎 · 等级 1-10 · 让子可调"
            case .xiangqi: return "内置引擎 · 等级 1-10 · 红黑任选"
            case .gomoku: return "自研棋型 AI · 五档难度 · 可提示"
            case .banqi: return "自研暗棋 AI · 五档难度"
            }
        }
        if index == 1 {
            switch app.kind {
            case .go: return "同机对局 · 局域网联机"
            case .xiangqi: return "同机对弈 · 局域网联机"
            default: return "同机轮流 · 局域网联机"
            }
        }
        switch app.kind {
        case .go: return "内置棋谱 · 支持导入 SGF"
        case .xiangqi: return "导入 PGN / FEN 逐步打谱"
        case .gomoku: return "无禁手 · 黑先 · 五连即胜"
        case .banqi: return "军衔 · 翻子 · 炮隔子吃"
        }
    }

    private func openEntry(_ index: Int) {
        if index == 0 {
            switch app.kind {
            case .go: showGoConfig = true
            case .xiangqi: showXqConfig = true
            case .gomoku: showGomokuConfig = true
            case .banqi: pendingBQ = BanqiSetup(mode: .ai, first: true, level: 5)
            }
        } else if index == 1 {
            localDialogKind = app.kind
        } else {
            if app.kind == .go || app.kind == .xiangqi {
                showLibrary = true
            } else {
                rulesKind = app.kind
            }
        }
    }

    // 墨白：发丝列表行
    private func entryRow(_ index: Int, _ title: String, _ desc: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(theme.prefixes[index])
                    .font(.qySerif(15))
                    .foregroundColor(theme.prefixColor)
                    .frame(width: 48, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.qySerif(18, weight: .bold))
                        .foregroundColor(theme.entryTitle)
                    Text(desc)
                        .font(.system(size: 13))
                        .foregroundColor(theme.entryDesc)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("›")
                    .font(.system(size: 22))
                    .foregroundColor(theme.sub)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 粉彩：错落圆角卡片
    private func entryCard(_ index: Int, _ title: String, _ desc: String,
                           leading: CGFloat, trailing: CGFloat,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(theme.prefixes[index])
                    .font(.qySerif(15))
                    .foregroundColor(theme.prefixColor)
                    .frame(width: 48, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.qySerif(18, weight: .bold))
                        .foregroundColor(theme.entryTitle)
                    Text(desc)
                        .font(.system(size: 13))
                        .foregroundColor(theme.entryDesc)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 0) {
                    Text("●").foregroundColor(theme.entryTitle)
                    Text("○").foregroundColor(theme.prefixColor)
                }
                .font(.system(size: 13))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: theme.entryRadius)
                    .fill(theme.entryBg[index % theme.entryBg.count])
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, leading)
        .padding(.trailing, trailing)
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(spacing: 12) {
            if theme.isHara {
                Hairline(color: theme.divider)
            }
            HStack(spacing: 8) {
                // 版本号从 Bundle 读取，随 project.yml 的 MARKETING_VERSION 自动同步
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                    .font(.system(size: 12))
                    .foregroundColor(theme.foot)
                Spacer(minLength: 8)
                Text("Powered by QingYi Engine")
                    .font(.system(size: 12))
                    .foregroundColor(theme.foot)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    // MARK: - 打开棋谱

    private func openRecord(_ url: URL) {
        if app.kind == .go {
            pendingGo = GoSetup(mode: .review, recordURL: url)
        } else {
            pendingXQ = XiangqiSetup(mode: .review, recordURL: url)
        }
    }
}

// MARK: - 围棋人机设置

struct GoConfigDialog: View {
    var theme: Theme
    var defaultSound: Bool
    var onStart: (Bool, GoSetup) -> Void
    var onCancel: () -> Void

    @State private var black = true
    @State private var level: Double = 10
    @State private var handicap = 0
    @State private var sound = true

    init(theme: Theme, defaultSound: Bool,
         onStart: @escaping (Bool, GoSetup) -> Void, onCancel: @escaping () -> Void) {
        self.theme = theme
        self.defaultSound = defaultSound
        self.onStart = onStart
        self.onCancel = onCancel
        _sound = State(initialValue: defaultSound)
    }

    var body: some View {
        DialogScaffold(title: "人机对弈 · 围棋", theme: theme, onDismiss: onCancel) {
            VStack(alignment: .leading, spacing: 18) {
                engineRow
                section("执子") {
                    HStack(spacing: 10) {
                        choice("执黑 · 先手", selected: black) { black = true }
                        choice("执白 · 后手", selected: !black) { black = false }
                    }
                }
                section("等级  \(Int(level))") {
                    ThemedSlider(value: $level, range: 1...10, step: 1, theme: theme)
                        .padding(.top, 2)
                }
                section("让子") {
                    HStack(spacing: 14) {
                        stepButton("−") { if handicap > 0 { handicap -= 1 } }
                        Text(handicap == 0 ? "不让子" : "让 \(handicap) 子")
                            .font(.system(size: 15))
                            .foregroundColor(theme.title)
                            .frame(minWidth: 70)
                        stepButton("+") { if handicap < 9 { handicap += 1 } }
                        Spacer(minLength: 0)
                    }
                }
                CheckRow(title: "落子音效", checked: sound, theme: theme) { sound.toggle() }
                Hairline(color: theme.dlgLine)
                HStack(spacing: 12) {
                    ThemedActionButton(title: "取消", theme: theme, action: onCancel)
                    ThemedActionButton(title: "开始对弈", kind: .primary, theme: theme) {
                        var setup = GoSetup(mode: .ai)
                        setup.playerColor = black ? .black : .white
                        setup.level = Int(level)
                        setup.handicap = handicap
                        onStart(sound, setup)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var engineRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("引擎")
                    .font(.system(size: 13))
                    .foregroundColor(theme.sub)
                    .frame(width: 44, alignment: .leading)
                Text("清弈 · 棋形引擎")
                    .font(.qySerif(15, weight: .semibold))
                    .foregroundColor(theme.title)
                Text("内置")
                    .font(.system(size: 10))
                    .foregroundColor(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent, lineWidth: 0.6))
                Spacer(minLength: 0)
            }
            Text("等级 1-3 由本地 AI 感知驱动，4-6 由 Pachi 引擎驱动，7-10 由 KataGo 神经网络驱动\n均为进程内运行，无需联网")
                .font(.system(size: 11))
                .foregroundColor(theme.foot)
                .lineSpacing(3)
                .padding(.leading, 54)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(theme.sub)
            content()
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(selected ? theme.btnText : theme.sub)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: theme.isHara ? 2 : 14)
                        .fill(selected ? (theme.isHara ? Color.white : theme.btnBg) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.isHara ? 2 : 14)
                        .stroke(selected ? theme.title : theme.btnStroke, lineWidth: 0.8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stepButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 16))
                .foregroundColor(theme.title)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(theme.btnStroke, lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 象棋人机设置

struct XiangqiConfigDialog: View {
    var theme: Theme
    var defaultHints: Bool
    var onStart: (Bool, XiangqiSetup) -> Void
    var onCancel: () -> Void

    @State private var red = true
    @State private var level: Double = 5
    @State private var hints = true

    init(theme: Theme, defaultHints: Bool,
         onStart: @escaping (Bool, XiangqiSetup) -> Void, onCancel: @escaping () -> Void) {
        self.theme = theme
        self.defaultHints = defaultHints
        self.onStart = onStart
        self.onCancel = onCancel
        _hints = State(initialValue: defaultHints)
    }

    var body: some View {
        DialogScaffold(title: "人机对弈 · 象棋", theme: theme, onDismiss: onCancel) {
            VStack(alignment: .leading, spacing: 18) {
                engineRow
                VStack(alignment: .leading, spacing: 9) {
                    Text("执子")
                        .font(.system(size: 13))
                        .foregroundColor(theme.sub)
                    HStack(spacing: 10) {
                        choice("执红 · 先手", selected: red) { red = true }
                        choice("执黑 · 后手", selected: !red) { red = false }
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("等级  \(Int(level))")
                        .font(.system(size: 13))
                        .foregroundColor(theme.sub)
                    ThemedSlider(value: $level, range: 1...10, step: 1, theme: theme)
                }
                CheckRow(title: "显示可走位置", checked: hints, theme: theme) { hints.toggle() }
                Hairline(color: theme.dlgLine)
                HStack(spacing: 12) {
                    ThemedActionButton(title: "取消", theme: theme, action: onCancel)
                    ThemedActionButton(title: "开始对弈", kind: .primary, theme: theme) {
                        var setup = XiangqiSetup(mode: .ai)
                        setup.playerColor = red ? .red : .black
                        setup.level = Int(level)
                        setup.hints = hints
                        onStart(hints, setup)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var engineRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("引擎")
                    .font(.system(size: 13))
                    .foregroundColor(theme.sub)
                    .frame(width: 44, alignment: .leading)
                Text("清弈 · Alpha-Beta 引擎")
                    .font(.qySerif(15, weight: .semibold))
                    .foregroundColor(theme.title)
                Spacer(minLength: 0)
                Text("内置")
                    .font(.system(size: 10))
                    .foregroundColor(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent, lineWidth: 0.6))
            }
            Text("等级 1-6 由本地搜索 AI 驱动，7-10 由 Pikafish 引擎驱动\n进程内静态链接，无需联网")
                .font(.system(size: 11))
                .foregroundColor(theme.foot)
                .lineSpacing(3)
                .padding(.leading, 54)
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(selected ? theme.btnText : theme.sub)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: theme.isHara ? 2 : 14)
                        .fill(selected ? (theme.isHara ? Color.white : theme.btnBg) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.isHara ? 2 : 14)
                        .stroke(selected ? theme.title : theme.btnStroke, lineWidth: 0.8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 棋谱库

struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    var theme: Theme
    var kind: GameKind
    var onOpen: (URL) -> Void

    @State private var importing = false
    @State private var errorText: String?
    @State private var records: [GoRecord] = []

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)
            VStack(spacing: 0) {
                HStack {
                    Text(kind == .go ? "棋谱欣赏" : "棋谱复盘")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundColor(theme.title)
                        .tracking(1)
                    Spacer()
                    Button("完成") { dismiss() }
                        .font(.system(size: 14, design: .serif))
                        .foregroundColor(theme.sub)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)

                Hairline(color: theme.dlgLine)
                    .padding(.horizontal, 24)

                if kind == .go {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            if records.isEmpty {
                                emptyHint("暂无内置棋谱")
                            }
                            ForEach(records) { record in
                                Button {
                                    onOpen(record.url)
                                    dismiss()
                                } label: {
                                    HStack(alignment: .center, spacing: 14) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(record.title)
                                                .font(.system(size: 16, weight: .semibold, design: .serif))
                                                .foregroundColor(theme.title)
                                                .lineLimit(1)
                                            Text(record.subtitle.isEmpty ? "\(record.size) 路" : record.subtitle)
                                                .font(.system(size: 11, design: .serif))
                                                .foregroundColor(theme.sub)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        Text("\(record.size) 路")
                                            .font(.system(size: 10, design: .serif))
                                            .foregroundColor(theme.foot)
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 16)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Hairline(color: theme.dlgLine)
                                    .padding(.horizontal, 24)
                            }
                            importRow
                        }
                        .padding(.top, 4)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            emptyHint("导入 PGN 棋谱文件开始复盘")
                            importRow
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 24)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: kind == .go
                ? [UTType(filenameExtension: "sgf") ?? .data]
                : [UTType(filenameExtension: "pgn") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let ext = kind == .go ? "sgf" : "pgn"
                let local = try Records.importFile(url, ext: ext)
                onOpen(local)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
        .alert("无法打开文件", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            if kind == .go { records = Records.bundledGoRecords() }
        }
    }

    private var importRow: some View {
        Button {
            importing = true
        } label: {
            HStack(spacing: 10) {
                Text("＋")
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundColor(theme.accent)
                Text(kind == .go ? "从文件导入 SGF" : "从文件导入 PGN")
                    .font(.system(size: 15, design: .serif))
                    .foregroundColor(theme.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, kind == .go ? 24 : 18)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: theme.isHara ? 2 : 14)
                    .fill(theme.isHara ? Color.clear : theme.btnBg.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.isHara ? 2 : 14)
                    .stroke(theme.btnStroke, lineWidth: theme.isHara ? 0.8 : 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, kind == .go ? 8 : 0)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, design: .serif))
            .foregroundColor(theme.foot)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }
}

// MARK: - 五子棋人机设置

struct GomokuConfigDialog: View {
    var theme: Theme
    var onStart: (GomokuSetup) -> Void
    var onCancel: () -> Void

    @State private var black = true
    @State private var level: Double = 3
    @State private var hints = true
    @State private var renju = false

    var body: some View {
        DialogScaffold(title: "人机对弈 · 五子棋", theme: theme, onDismiss: onCancel) {
            VStack(alignment: .leading, spacing: 18) {
                Text("自研棋型 AI · 五档难度")
                    .font(.system(size: 13))
                    .foregroundColor(theme.sub)

                section("难度  \(GomokuAi.levelName(Int(level)))") {
                    ThemedSlider(value: $level, range: 1...5, step: 1, theme: theme)
                        .padding(.top, 2)
                }

                section("执子") {
                    HStack(spacing: 10) {
                        choice("执黑 · 先手", selected: black) { black = true }
                        choice("执白 · 后手", selected: !black) { black = false }
                    }
                }

                CheckRow(title: "落点提示", checked: hints, theme: theme) { hints.toggle() }
                CheckRow(title: "黑棋禁手（连珠）", checked: renju, theme: theme) { renju.toggle() }

                Hairline(color: theme.dlgLine)

                HStack(spacing: 12) {
                    ThemedActionButton(title: "取消", theme: theme, action: onCancel)
                    ThemedActionButton(title: "开始对弈", kind: .primary, theme: theme) {
                        var setup = GomokuSetup(mode: .ai)
                        setup.playerColor = black ? GomokuGame.black : GomokuGame.white
                        setup.level = Int(level)
                        setup.renju = renju
                        setup.hints = hints
                        onStart(setup)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(theme.sub)
            content()
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(selected ? theme.btnText : theme.sub)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: theme.isHara ? 2 : 14)
                        .fill(selected ? (theme.isHara ? Color.white : theme.btnBg) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.isHara ? 2 : 14)
                        .stroke(selected ? theme.title : theme.btnStroke, lineWidth: 0.8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
