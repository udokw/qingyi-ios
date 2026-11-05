import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var app: AppState
    @State private var goSetup: GoSetup?
    @State private var xqSetup: XiangqiSetup?
    @State private var showGoConfig = false
    @State private var showXqConfig = false
    @State private var showLibrary = false

    private var theme: Theme { app.theme }

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    if theme.isHara {
                        haraTitle
                    } else {
                        monumentTitle
                    }
                    segmented
                        .padding(.top, theme.isHara ? 18 : 22)
                    entries
                        .padding(.top, theme.isHara ? 6 : 20)
                    Spacer(minLength: 18)
                    footer
                        .padding(.bottom, 10)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .frame(maxWidth: .infinity)
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
        }
        .animation(.easeInOut(duration: 0.18), value: showGoConfig)
        .animation(.easeInOut(duration: 0.18), value: showXqConfig)
        .sheet(isPresented: $showLibrary) {
            LibraryView(theme: theme, kind: app.kind) { url in
                showLibrary = false
                openRecord(url)
            }
        }
        .fullScreenCover(item: $goSetup) { setup in
            GoGameView(setup: setup)
                .environmentObject(app)
        }
        .fullScreenCover(item: $xqSetup) { setup in
            XiangqiGameView(setup: setup)
                .environmentObject(app)
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
    }

    @State private var pendingGo: GoSetup?
    @State private var pendingXQ: XiangqiSetup?

    // MARK: - 头部

    private var header: some View {
        HStack {
            if theme.isHara {
                Text("清 弈 · 棋 道")
                    .font(.system(size: 11, weight: .regular, design: .serif))
                    .tracking(3)
                    .foregroundColor(theme.sub)
            } else {
                Text("QINGYI")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(3)
                    .foregroundColor(theme.foot)
            }
            Spacer()
            Button {
                app.toggleTheme()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                    Text("主题 · \(theme.name)")
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .foregroundColor(theme.sub)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    // MARK: - 标题区

    private var haraTitle: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("清弈")
                        .font(.system(size: 42, weight: .bold, design: .serif))
                        .foregroundColor(theme.title)
                        .tracking(6)
                    Text("围棋与象棋 · 一局清欢")
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .foregroundColor(theme.sub)
                        .tracking(1)
                }
                SealView(text: "围\n象", size: 38, theme: theme)
                Spacer(minLength: 0)
            }
            BoardMotif(theme: theme)
                .frame(maxWidth: 210, alignment: .leading)
        }
        .padding(.top, 26)
    }

    private var monumentTitle: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("清弈")
                        .font(.system(size: 40, weight: .bold, design: .serif))
                        .foregroundColor(theme.title)
                        .tracking(5)
                    Text("围棋与象棋 · 静心一手")
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .foregroundColor(theme.sub)
                        .tracking(1)
                }
                SealView(text: "清\n弈", size: 32, theme: theme)
                Spacer(minLength: 0)
            }
            BoardMotif(theme: theme)
                .frame(maxWidth: 240)
        }
        .padding(.top, 26)
    }

    // MARK: - 切换

    private var segmented: some View {
        HStack(spacing: 0) {
            segmentButton(kind: .go, title: "围棋", en: "GO")
            segmentButton(kind: .xiangqi, title: "象棋", en: "XIANGQI")
        }
    }

    @ViewBuilder
    private func segmentButton(kind: GameKind, title: String, en: String) -> some View {
        let selected = app.kind == kind
        Button {
            app.kind = kind
        } label: {
            if theme.isHara {
                VStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 16, weight: selected ? .bold : .regular, design: .serif))
                        .foregroundColor(selected ? theme.title : theme.sub)
                        .tracking(2)
                    Rectangle()
                        .fill(selected ? theme.accent : Color.clear)
                        .frame(height: 2)
                        .frame(maxWidth: 34)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .contentShape(Rectangle())
            } else {
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundColor(selected ? theme.title : theme.sub)
                    Text(en)
                        .font(.system(size: 8, weight: .regular))
                        .tracking(1.5)
                        .foregroundColor(selected ? theme.sub : theme.foot)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(selected ? Color.white.opacity(0.75) : Color.clear)
                )
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: theme.isHara ? nil : .infinity)
    }

    // MARK: - 入口

    private var entries: some View {
        VStack(spacing: theme.isHara ? 0 : 12) {
            entry(index: 0,
                  title: app.kind == .go ? "人机对弈" : "与清弈对弈",
                  desc: app.kind == .go ? "内置引擎 · 等级 1-10" : "红黑任选 · 内置引擎") {
                if app.kind == .go { showGoConfig = true } else { showXqConfig = true }
            }
            if theme.isHara {
                Hairline(color: theme.divider)
            }
            entry(index: 1, title: "本地双人", desc: "同一设备轮流落子") {
                if app.kind == .go {
                    pendingGo = GoSetup(mode: .local)
                } else {
                    pendingXQ = XiangqiSetup(mode: .local)
                }
            }
            if theme.isHara {
                Hairline(color: theme.divider)
            }
            entry(index: 2,
                  title: app.kind == .go ? "棋谱欣赏" : "棋谱复盘",
                  desc: app.kind == .go ? "SGF 棋谱 · 逐手打谱" : "PGN 导入 · 逐手复盘") {
                showLibrary = true
            }
            if theme.isHara {
                Hairline(color: theme.divider)
            }
        }
    }

    private func entry(index: Int, title: String, desc: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if theme.isHara {
                HStack(spacing: 16) {
                    Text("\(theme.prefixes[index]).")
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .foregroundColor(theme.prefixColor)
                        .frame(width: 22, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 19, weight: .bold, design: .serif))
                            .foregroundColor(theme.entryTitle)
                            .tracking(1)
                        Text(desc)
                            .font(.system(size: 12, weight: .regular, design: .serif))
                            .foregroundColor(theme.entryDesc)
                    }
                    Spacer(minLength: 0)
                    Text("›")
                        .font(.system(size: 20, weight: .regular, design: .serif))
                        .foregroundColor(theme.foot)
                }
                .padding(.vertical, 19)
                .contentShape(Rectangle())
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.system(size: 19, weight: .bold, design: .serif))
                            .foregroundColor(theme.entryTitle)
                        Text(desc)
                            .font(.system(size: 12, weight: .regular, design: .serif))
                            .foregroundColor(theme.entryDesc)
                    }
                    Spacer(minLength: 0)
                    Text(theme.prefixes[index])
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .foregroundColor(theme.prefixColor)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: theme.entryRadius)
                        .fill(LinearGradient(colors: [theme.entryBg[index],
                                                      theme.entryBg[index].opacity(0.55)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                )
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 6) {
            Text(theme.isHara ? "内置引擎 · 无需联网" : "落子无悔 · 静心一手")
                .font(.system(size: 11, weight: .regular, design: .serif))
                .tracking(1.5)
                .foregroundColor(theme.foot)
            Text("清弈 v1.0.0 · iOS")
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(theme.foot.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
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

// MARK: - 棋盘纹样

struct BoardMotif: View {
    var theme: Theme

    var body: some View {
        Canvas { context, size in
            let n: CGFloat = 5
            let pad: CGFloat = 5
            let stepX = (size.width - pad * 2) / (n - 1)
            let stepY = (size.height - pad * 2) / (n - 1)
            var path = Path()
            for i in 0..<5 {
                let x = pad + CGFloat(i) * stepX
                path.move(to: CGPoint(x: x, y: pad))
                path.addLine(to: CGPoint(x: x, y: size.height - pad))
                let y = pad + CGFloat(i) * stepY
                path.move(to: CGPoint(x: pad, y: y))
                path.addLine(to: CGPoint(x: size.width - pad, y: y))
            }
            context.stroke(path, with: .color(theme.isHara ? theme.divider : theme.dlgLine.opacity(0.9)), lineWidth: 0.7)
            let cx = pad + 2 * stepX
            let cy = pad + 2 * stepY
            let stone = CGRect(x: cx - 3.6, y: cy - 3.6, width: 7.2, height: 7.2)
            context.fill(Path(ellipseIn: stone), with: .color(theme.accent))
        }
        .frame(height: 36)
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
                            .font(.system(size: 15, design: .serif))
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
        HStack(spacing: 10) {
            Text("引擎")
                .font(.system(size: 13, design: .serif))
                .foregroundColor(theme.sub)
                .frame(width: 44, alignment: .leading)
            Text("清弈引擎")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundColor(theme.title)
            Text("内置")
                .font(.system(size: 10))
                .foregroundColor(theme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent, lineWidth: 0.6))
            Spacer(minLength: 0)
            Text("无需下载")
                .font(.system(size: 10))
                .foregroundColor(theme.foot)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13, design: .serif))
                .foregroundColor(theme.sub)
            content()
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, design: .serif))
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
                HStack(spacing: 10) {
                    Text("引擎")
                        .font(.system(size: 13, design: .serif))
                        .foregroundColor(theme.sub)
                        .frame(width: 44, alignment: .leading)
                    Text("清弈象棋引擎")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundColor(theme.title)
                    Spacer(minLength: 0)
                    Text("内置")
                        .font(.system(size: 10))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent, lineWidth: 0.6))
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("执子")
                        .font(.system(size: 13, design: .serif))
                        .foregroundColor(theme.sub)
                    HStack(spacing: 10) {
                        choice("执红 · 先手", selected: red) { red = true }
                        choice("执黑 · 后手", selected: !red) { red = false }
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("等级  \(Int(level))")
                        .font(.system(size: 13, design: .serif))
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

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, design: .serif))
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
                                        Text("\(record.size)路")
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
        .padding(.horizontal, kind == .go ? 0 : 0)
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
