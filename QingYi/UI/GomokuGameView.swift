import SwiftUI

/// 五子棋单机页：结构与围棋页一致（顶部返回/标题/状态 → 棋盘贴屏 → 操作区）。
/// 文案与按钮对齐 Android `GomokuActivity`。
struct GomokuGameView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model: GomokuGameModel
    @Environment(\.dismiss) private var dismiss

    @State private var showRecords = false
    @State private var records: [URL] = []

    init(setup: GomokuSetup) {
        _model = StateObject(wrappedValue: GomokuGameModel(setup: setup))
    }

    private var theme: Theme { app.theme }

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)
            VStack(spacing: 0) {
                header

                Spacer(minLength: 8)

                GeometryReader { geo in
                    let side = GameLayout.fittedSide(availableWidth: geo.size.width,
                                                     availableHeight: geo.size.height,
                                                     isXiangqi: false)
                    GomokuBoardView(board: model.board,
                                    size: GomokuGame.boardSize,
                                    lastMove: model.lastMove,
                                    winLine: model.winLine,
                                    hint: model.hint,
                                    theme: theme) { x, y in
                        model.tap(x, y)
                    }
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, -GameLayout.boardBleed)
                .padding(.top, 10)

                if !theme.isHara {
                    Text("五 子 连 珠 · 一 局 清 弈")
                        .font(.system(size: 11))
                        .tracking(3.3)
                        .foregroundColor(theme.foot)
                        .padding(.top, 12)
                }

                actionGrid
                    .padding(.top, theme.isHara ? 18 : 26)

                if theme.isHara {
                    signature
                        .padding(.top, 16)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, GameLayout.columnInset)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .onAppear {
            SoundPlayer.shared.setEnabled(app.goSound)
        }
        .alert(item: $model.alert) { alert in
            if let confirmTitle = alert.confirmTitle {
                return Alert(title: Text(alert.title),
                             message: Text(alert.message),
                             primaryButton: .destructive(Text(confirmTitle)) {
                                 alert.onConfirm?()
                             },
                             secondaryButton: .cancel(Text(alert.cancelTitle ?? "继续")) {
                                 if alert.cancelTitle == "返回主页" { dismiss() }
                                 alert.onCancel?()
                             })
            }
            return Alert(title: Text(alert.title), message: Text(alert.message),
                         dismissButton: .default(Text("好")))
        }
        .sheet(isPresented: $showRecords) {
            NavigationView {
                List(records, id: \.self) { url in
                    Button {
                        showRecords = false
                        model.loadRecord(url)
                    } label: {
                        Text(url.lastPathComponent)
                            .font(.system(size: 15))
                            .foregroundColor(theme.title)
                    }
                }
                .navigationTitle("读取棋谱（逐手回放）")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showRecords = false }
                    }
                }
            }
        }
    }

    // MARK: - 顶部

    @ViewBuilder
    private var header: some View {
        if theme.isHara {
            ZStack {
                Text(model.eyebrowText)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .tracking(3.9)
                    .foregroundColor(theme.sub)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 0) {
                    backButton
                    Spacer(minLength: 0)
                    MiniSeal(text: "清", theme: theme)
                }
            }

            HStack(spacing: 8) {
                Text(model.leftTitle)
                    .font(.qySerif(18, weight: .bold))
                    .foregroundColor(theme.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                statusLine
            }
            .padding(.top, 10)

            Hairline(color: theme.divider)
                .padding(.top, 10)
        } else {
            HStack(spacing: 0) {
                backButton
                Spacer(minLength: 0)
            }
            Text(model.statusText)
                .font(.qySerif(19, weight: .bold))
                .foregroundColor(theme.title)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            Text(model.subTitle)
                .font(.system(size: 14))
                .tracking(1.4)
                .foregroundColor(theme.sub)
                .padding(.top, 6)
        }
    }

    private var backButton: some View {
        Button {
            if model.isOver || !model.canUndo {
                dismiss()
            } else {
                model.setAlert(GameAlert(title: "结束对局",
                                         message: "结束本局并返回主页?",
                                         confirmTitle: "结束本局",
                                         cancelTitle: "继续对局") {
                    dismiss()
                })
            }
        } label: {
            Text("‹")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundColor(theme.sub)
                .frame(width: 32, height: 24, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusLine: some View {
        Group {
            if let plain = model.plainStatus {
                Text(plain).foregroundColor(theme.title)
            } else {
                Text("轮到 ").foregroundColor(theme.title)
                    + Text(model.turnMarker).foregroundColor(theme.accent)
                    + Text("行棋").foregroundColor(theme.title)
            }
        }
        .font(.qySerif(17))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }

    // MARK: - 操作区

    private var actionGrid: some View {
        Group {
            if theme.isHara {
                VStack(spacing: 0) {
                    Hairline(color: theme.divider)
                    HStack(spacing: 0) {
                        gridButton("悔棋", "UNDO") { model.undo() }
                        verticalDivider
                        gridButton("提示", "HINT") { model.requestHint() }
                        verticalDivider
                        gridButton("认输", "RESIGN", danger: true) { model.resign() }
                    }
                    .frame(height: GameLayout.actionRowHeight)
                    Hairline(color: theme.divider)
                    HStack(spacing: 0) {
                        gridButton("新局", "NEW") { model.restart() }
                        verticalDivider
                        gridButton("存谱", "SAVE SGF") { model.saveRecord() }
                        verticalDivider
                        gridButton("读谱", "OPEN SGF") {
                            records = model.records()
                            if records.isEmpty {
                                model.setAlert(GameAlert(title: "读谱", message: "目录里还没有 .gmk 棋谱"))
                            } else {
                                showRecords = true
                            }
                        }
                        verticalDivider
                        gridButton(model.renju ? "禁手开" : "禁手关", "RENJU") { model.toggleRenju() }
                    }
                    .frame(height: GameLayout.actionRowHeight)
                    Hairline(color: theme.divider)
                }
            } else {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        pill("悔棋") { model.undo() }
                        pill("提示") { model.requestHint() }
                        pill("认输", danger: true) { model.resign() }
                    }
                    HStack(spacing: 12) {
                        pill("新局") { model.restart() }
                        pill("存谱") { model.saveRecord() }
                        pill("读谱") {
                            records = model.records()
                            if records.isEmpty {
                                model.setAlert(GameAlert(title: "读谱", message: "目录里还没有 .gmk 棋谱"))
                            } else {
                                showRecords = true
                            }
                        }
                        pill(model.renju ? "禁手开" : "禁手关") { model.toggleRenju() }
                    }
                }
                .padding(.horizontal, GameLayout.columnInset)
            }
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(width: 0.6)
    }

    private func gridButton(_ title: String, _ en: String,
                            danger: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GameActionCell(title: title, en: en, danger: danger, theme: theme)
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, danger: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundColor(danger ? theme.dangerText : theme.btnText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: theme.btnRadius)
                        .fill(danger ? theme.entryBg[0] : theme.btnBg)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var signature: some View {
        Text("清 弈 · 五 子 棋")
            .font(.system(size: 10))
            .tracking(2.4)
            .foregroundColor(theme.foot)
    }
}
