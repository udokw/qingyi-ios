import SwiftUI

struct GoGameView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model: GoGameModel
    @Environment(\.dismiss) private var dismiss

    init(setup: GoSetup) {
        _model = StateObject(wrappedValue: GoGameModel(setup: setup))
    }

    private var theme: Theme { app.theme }
    private var isReview: Bool { model.mode == .review }

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)
            VStack(spacing: 0) {
                header

                Spacer(minLength: 8)

                GoBoardView(board: model.game.board,
                            size: model.game.size,
                            lastMove: model.lastMove,
                            ko: model.game.ko,
                            territory: model.territory,
                            theme: theme) { x, y in
                    model.tap(x, y)
                }
                // 棋盘用比文字行更窄的留白（GameLayout.boardInset），
                // 这里把父级 6pt 的留白抵消掉一部分，使实际边长 = 屏宽 − 2×2。
                .padding(.horizontal, -GameLayout.boardBleed)
                .padding(.top, 10)

                if !theme.isHara {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: 0xD8C9B8))
                        .frame(width: 140, height: 10)
                        .padding(.top, 8)
                    Text("安 静 的 一 手")
                        .font(.system(size: 11))
                        .tracking(3.3)
                        .foregroundColor(theme.foot)
                        .padding(.top, 16)
                }

                if isReview {
                    commentBlock
                        .padding(.top, 12)
                    reviewGrid
                        .padding(.top, 12)
                } else {
                    actionGrid
                        .padding(.top, 40)
                }

                if theme.isHara {
                    signature
                        .padding(.top, 24)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, GameLayout.columnInset)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .statusBarHidden(false)
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
                             secondaryButton: .cancel(Text("取消")))
            }
            return Alert(title: Text(alert.title), message: Text(alert.message),
                         dismissButton: .default(Text("好")))
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheetView(url: item.url, title: item.title)
        }
    }

    // MARK: - 顶部

    @ViewBuilder
    private var header: some View {
        if theme.isHara {
            ZStack {
                Text(model.eyebrowText)
                    .font(.system(size: 13))
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
                .font(.qySerif(19, weight: .bold))
                .foregroundColor(theme.title)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            Text(model.subTitle)
                .font(.system(size: 14, weight: .regular, design: .serif))
                .tracking(1.4)
                .foregroundColor(theme.sub)
                .padding(.top, 6)
            Hairline(color: theme.dlgLine)
                .padding(.top, 10)
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
                Text(plain)
                    .foregroundColor(theme.title)
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

    // MARK: - 复盘批注

    @ViewBuilder
    private var commentBlock: some View {
        if let comment = model.comment, !comment.isEmpty {
            Text(comment)
                .font(.system(size: 12))
                .foregroundColor(theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
        }
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
                        gridButton("停一手", "PASS") { model.pass() }
                        verticalDivider
                        gridButton("形势", "SCORE EST.") { model.estimate() }
                    }
                    .frame(height: GameLayout.actionRowHeight)
                    Hairline(color: theme.divider)
                    HStack(spacing: 0) {
                        gridButton("数子", "COUNT") { model.countScore() }
                        verticalDivider
                        gridButton("认输", "RESIGN", danger: true) { model.resign() }
                        verticalDivider
                        gridButton("存谱", "SAVE SGF") { model.save() }
                    }
                    .frame(height: GameLayout.actionRowHeight)
                    Hairline(color: theme.divider)
                }
            } else {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        pill("悔棋") { model.undo() }
                        pill("停一手") { model.pass() }
                        pill("形势") { model.estimate() }
                    }
                    HStack(spacing: 12) {
                        pill("数子") { model.countScore() }
                        pill("认输", danger: true) { model.resign() }
                        pill("存谱") { model.save() }
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
                        gridButton("◀ 上一手", "PREV") { model.reviewStep(-1) }
                        verticalDivider
                        gridButton("下一手 ▶", "NEXT", selected: true) { model.reviewStep(1) }
                    }
                    .frame(height: GameLayout.actionRowHeight)
                    Hairline(color: theme.divider)
                }
            } else {
                HStack(spacing: 12) {
                    pill("◀ 上一手") { model.reviewStep(-1) }
                    pill("下一手 ▶", primary: true) { model.reviewStep(1) }
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
            GameActionCell(title: title, en: en, danger: danger,
                           selected: selected, theme: theme)
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
        Text(isReview ? "清 弈 · 棋 谱 打 谱" : "清 弈 引 擎 · 围 棋")
            .font(.system(size: 11))
            .tracking(2.75)
            .foregroundColor(theme.foot)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
