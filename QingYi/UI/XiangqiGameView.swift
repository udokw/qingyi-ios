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
                topBar
                statusBlock
                    .padding(.horizontal, 22)
                    .padding(.top, theme.isHara ? 10 : 14)
                board
                    .padding(.horizontal, 12)
                    .padding(.top, theme.isHara ? 8 : 12)
                Spacer(minLength: 6)
                if isReview {
                    reviewControls
                } else {
                    actionGrid
                }
                footer
            }
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

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Text("‹")
                        .font(.system(size: 20, weight: .regular, design: .serif))
                    Text("返回")
                        .font(.system(size: 13, design: .serif))
                }
                .foregroundColor(theme.sub)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if theme.isHara {
                HStack(spacing: 8) {
                    Text("清 弈 · 象 棋")
                        .font(.system(size: 11, weight: .regular, design: .serif))
                        .tracking(2)
                        .foregroundColor(theme.sub)
                    MiniSeal(text: "象", theme: theme)
                }
            } else {
                Text(model.leftTitle)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundColor(theme.sub)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    // MARK: - 状态

    private var statusBlock: some View {
        VStack(spacing: theme.isHara ? 8 : 6) {
            if theme.isHara {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.leftTitle)
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundColor(theme.title)
                    Spacer(minLength: 0)
                    Text(model.statusText)
                        .font(.system(size: 15, weight: .regular, design: .serif))
                        .foregroundColor(theme.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text(model.statusText)
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundColor(theme.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if !theme.isHara {
                Text(model.subTitle)
                    .font(.system(size: 11, weight: .regular, design: .serif))
                    .foregroundColor(theme.sub)
            }
            if isReview, let comment = model.comment, !comment.isEmpty {
                Text(comment)
                    .font(.system(size: 11, design: .serif))
                    .foregroundColor(theme.sub)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline(color: theme.isHara ? theme.divider : theme.dlgLine)
                .padding(.top, 4)
        }
    }

    // MARK: - 棋盘

    private var board: some View {
        XiangqiBoardView(board: model.game.board,
                         selection: model.selection,
                         hints: model.hints,
                         lastMove: model.lastMove,
                         theme: theme,
                         onTap: { x, y in model.tap(x, y) },
                         onDrag: { fx, fy, tx, ty in
                             model.drag(from: GoPoint(x: fx, y: fy), to: GoPoint(x: tx, y: ty))
                         })
        .clipShape(RoundedRectangle(cornerRadius: theme.isHara ? 2 : 8))
        .overlay(
            RoundedRectangle(cornerRadius: theme.isHara ? 2 : 8)
                .stroke(theme.isHara ? theme.divider : Color.clear, lineWidth: 0.6)
        )
    }

    // MARK: - 按钮

    private var actionGrid: some View {
        VStack(spacing: 0) {
            if theme.isHara {
                Hairline(color: theme.divider)
                HStack(spacing: 0) {
                    gridButton("悔棋", "UNDO", .normal) { model.undo() }
                    verticalDivider
                    gridButton("认输", "RESIGN", .danger) { model.resign() }
                    verticalDivider
                    gridButton("求和", "DRAW", .normal) { model.agreeDraw() }
                }
                Hairline(color: theme.divider)
            } else {
                HStack(spacing: 8) {
                    pill("悔棋", .normal) { model.undo() }
                    pill("认输", .danger) { model.resign() }
                    pill("求和", .normal) { model.agreeDraw() }
                }
                .padding(.top, 26)
                .padding(.bottom, 6)
                .padding(.horizontal, 18)
            }
        }
    }

    private var reviewControls: some View {
        HStack(spacing: 10) {
            ThemedActionButton(title: "◀ 上一手", subtitle: "PREV", theme: theme) {
                model.reviewStep(-1)
            }
            ThemedActionButton(title: "下一手 ▶", subtitle: "NEXT", kind: .primary, theme: theme) {
                model.reviewStep(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(width: 0.6)
            .padding(.vertical, 6)
    }

    private func gridButton(_ title: String, _ en: String, _ kind: ActionKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundColor(kind == .danger ? theme.dangerText : theme.title)
                Text(en)
                    .font(.system(size: 9, weight: .regular, design: .serif))
                    .tracking(1)
                    .foregroundColor(theme.foot)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, _ kind: ActionKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundColor(kind == .danger ? theme.dangerText : theme.btnText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(kind == .danger ? theme.entryBg[0] : theme.btnBg)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 4) {
            if theme.isHara {
                Hairline(color: theme.divider)
                    .padding(.horizontal, 22)
                Text(isReview ? "棋 谱 复 盘 · 清 弈" : "清 弈 · 象 棋 引 擎")
                    .font(.system(size: 9, weight: .regular, design: .serif))
                    .tracking(2)
                    .foregroundColor(theme.foot)
                    .padding(.top, 8)
            } else {
                Text(isReview ? "逐手回放 · 清弈" : "楚河汉界 · 清弈")
                    .font(.system(size: 10, weight: .regular, design: .serif))
                    .foregroundColor(theme.foot)
            }
        }
        .padding(.bottom, 8)
    }
}
