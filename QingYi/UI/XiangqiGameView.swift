import SwiftUI

struct XiangqiGameView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model: XiangqiGameModel
    @Environment(\.dismiss) private var dismiss

    init(setup: XiangqiSetup) {
        _model = StateObject(wrappedValue: XiangqiGameModel(setup: setup))
    }

    private var theme: Theme { app.theme }
    private var isReview: Bool { model.mode == .review }

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)
            VStack(spacing: 0) {
                header

                Spacer(minLength: 8)

                XiangqiBoardView(board: model.game.board,
                                 selection: model.selection,
                                 hints: model.hints,
                                 lastMove: model.lastMove,
                                 theme: theme,
                                 onTap: { x, y in model.tap(x, y) },
                                 onDrag: { fx, fy, tx, ty in
                                     model.drag(from: GoPoint(x: fx, y: fy),
                                                to: GoPoint(x: tx, y: ty))
                                 })
                    .padding(.top, 8)

                Text(model.moveLine)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .foregroundColor(theme.sub)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)

                if !theme.isHara {
                    Text("楚 河 汉 界 · 一 局 清 弈")
                        .font(.system(size: 11, weight: .regular, design: .serif))
                        .tracking(3.3)
                        .foregroundColor(theme.foot)
                        .padding(.top, 6)
                }

                if isReview {
                    reviewGrid
                        .padding(.top, 12)
                } else {
                    actionGrid
                        .padding(.top, theme.isHara ? 22 : 40)
                }

                if theme.isHara {
                    signature
                        .padding(.top, 20)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .onAppear {
            SoundPlayer.shared.setEnabled(true)
        }
        .alert(item: $model.alert) { alert in
            if let confirmTitle = alert.confirmTitle {
                return Alert(title: Text(alert.title),
                             message: Text(alert.message),
                             primaryButton: .destructive(Text(confirmTitle)) {
                                 alert.onConfirm?()
                             },
                             secondaryButton: .cancel(Text("取消")))
            }
            return Alert(title: Text(alert.title), message: Text(alert.message),
                         dismissButton: .default(Text("好")))
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
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundColor(theme.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                haraStatusLine
            }
            .padding(.top, 10)

            Hairline(color: theme.divider)
                .padding(.top, 10)
        } else {
            HStack(spacing: 0) {
                backButton
                Spacer(minLength: 0)
            }
            Text(model.monumentStatus)
                .font(.system(size: 19, weight: .bold, design: .serif))
                .foregroundColor(theme.title)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            Text(model.detailSubtitle)
                .font(.system(size: 14, weight: .regular, design: .serif))
                .tracking(1.4)
                .foregroundColor(theme.sub)
                .padding(.top, 6)
        }
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Text("‹")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundColor(theme.sub)
                .frame(width: 32, height: 24, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var haraStatusLine: some View {
        Group {
            if let plain = model.plainStatus {
                Text(plain).foregroundColor(theme.title)
            } else {
                statusTurnText
            }
        }
        .font(.system(size: 17, weight: .regular, design: .serif))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }

    private var statusTurnText: Text {
        var text = Text("轮到 ").foregroundColor(theme.title)
            + Text(model.turnMarker).foregroundColor(theme.accent)
            + Text("行棋").foregroundColor(theme.title)
        if model.game.inCheck(model.game.turn) {
            text = text + Text(" · 将军！").foregroundColor(theme.title)
        }
        return text
    }

    // MARK: - 操作网格

    private var actionGrid: some View {
        Group {
            if theme.isHara {
                VStack(spacing: 0) {
                    Hairline(color: theme.divider)
                    HStack(spacing: 0) {
                        gridButton("悔棋", "UNDO") { model.undo() }
                        verticalDivider
                        gridButton("认输", "RESIGN", danger: true) { model.resign() }
                        verticalDivider
                        gridButton(model.mode == .ai ? "重开" : "求和",
                                   model.mode == .ai ? "RESTART" : "DRAW") {
                            if model.mode == .ai { model.restart() } else { model.agreeDraw() }
                        }
                    }
                    .frame(height: 56)
                    Hairline(color: theme.divider)
                }
            } else {
                HStack(spacing: 12) {
                    pill("悔棋") { model.undo() }
                    pill("认输", danger: true) { model.resign() }
                    pill(model.mode == .ai ? "重开" : "求和") {
                        if model.mode == .ai { model.restart() } else { model.agreeDraw() }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private var reviewGrid: some View {
        Group {
            if theme.isHara {
                VStack(spacing: 0) {
                    Hairline(color: theme.divider)
                    HStack(spacing: 0) {
                        gridButton("◀ 上一步", "PREV") { model.reviewStep(-1) }
                        verticalDivider
                        gridButton("下一步 ▶", "NEXT", selected: true) { model.reviewStep(1) }
                    }
                    .frame(height: 56)
                    Hairline(color: theme.divider)
                }
            } else {
                HStack(spacing: 12) {
                    pill("◀ 上一步") { model.reviewStep(-1) }
                    pill("下一步 ▶", primary: true) { model.reviewStep(1) }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(width: 0.6)
    }

    private func gridButton(_ title: String, _ en: String,
                            danger: Bool = false, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundColor(danger ? theme.dangerText : (selected ? theme.primaryText : theme.title))
                Text(en)
                    .font(.system(size: 9, weight: .regular, design: .serif))
                    .tracking(1)
                    .foregroundColor(selected ? theme.primaryText.opacity(0.7) : theme.sub)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? theme.primaryBg : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, danger: Bool = false, primary: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundColor(primary ? theme.primaryText : (danger ? theme.dangerText : theme.btnText))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: theme.btnRadius)
                        .fill(primary ? theme.primaryBg : (danger ? theme.entryBg[0] : theme.btnBg))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部签字

    private var signature: some View {
        Text(isReview ? "清 弈 · 棋 谱 复 盘" : "清 弈 引 擎 · 象 棋")
            .font(.system(size: 11, weight: .regular, design: .serif))
            .tracking(2.75)
            .foregroundColor(theme.foot)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
