import SwiftUI
import UIKit

/// 暗棋单机页：横屏、棋盘铺满长边，常驻只有「轮到谁」与「红/黑/暗计数」。
/// 操作面板由长按棋盘、右下 ⋯ 呼出（安卓另有系统返回键，iOS 用这两种入口替代）。
struct BanqiGameView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model: BanqiGameModel
    @Environment(\.dismiss) private var dismiss

    @State private var showPanel = false

    init(setup: BanqiSetup) {
        _model = StateObject(wrappedValue: BanqiGameModel(setup: setup))
    }

    private var theme: Theme { app.theme }

    var body: some View {
        ZStack {
            PaperBackground(theme: theme)

            BanqiBoardView(board: model.codes,
                           faceUp: model.faceUp,
                           selection: model.selection,
                           legalTargets: model.legalTargets,
                           flipped: model.flipped,
                           theme: theme,
                           interactive: !model.thinking) { x, y in
                model.tap(x, y)
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
                panel
                    .transition(.move(edge: .trailing))
            }
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
    }

    // MARK: - 常驻 HUD

    private var hud: some View {
        VStack {
            HStack(spacing: 8) {
                Text(model.turnText)
                    .font(.system(size: 13))
                    .tracking(1.3)
                    .foregroundColor(Color(hex: 0x1A1A1A))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(model.countText)
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
                    Button {
                        closePanel()
                    } label: {
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
                panelRow("悔棋") { model.undo() }
                divider
                panelRow("认输", danger: true) { model.resign() }
                divider
                panelRow("难度") {
                    model.cycleLevel()
                } trailing: {
                    Text(model.levelText)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: 0x9A9384))
                }
                divider
                panelRow("重新开局") { model.restart() }
                Spacer(minLength: 0)
                divider
                panelRow("返回主页", danger: true) {
                    closePanel()
                    dismiss()
                }
            }
            .frame(width: 252)
            .background(PaperBackground(theme: theme))
            .padding(.vertical, 12)
            .padding(.trailing, 12)
        }
        .ignoresSafeArea()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(hex: 0xDDD6C4))
            .frame(height: 1)
    }

    private func panelRow(_ title: String, danger: Bool = false,
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

    private func panelRow<Trailing: View>(_ title: String,
                                          _ action: @escaping () -> Void,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: 0x1A1A1A))
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func closePanel() {
        withAnimation(.easeOut(duration: 0.16)) { showPanel = false }
    }
}

/// 只在暗棋页临时锁定横屏；离开后恢复竖屏。
enum BanqiOrientation {
    static func apply(landscape: Bool) {
        if #available(iOS 16.0, *) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIDevice.current.setValue(landscape ? UIInterfaceOrientation.landscapeRight.rawValue
                                                : UIInterfaceOrientation.portrait.rawValue,
                                      forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }
    }
}
