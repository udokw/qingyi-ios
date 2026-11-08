import SwiftUI

// MARK: - 发丝线

struct Hairline: View {
    var color: Color
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 0.6)
    }
}

// MARK: - 印章

struct SealView: View {
    var text: String
    var size: CGFloat = 34
    var theme: Theme

    var body: some View {
        Text(text)
            .font(.system(size: size / 3.0, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(-2)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 2).fill(theme.accent))
    }
}

struct MiniSeal: View {
    var text: String
    var theme: Theme
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 2).fill(theme.accent))
    }
}

/// 主页标题旁的竖排朱红小印（清 / 弈）
struct TitleSeal: View {
    var text: String = "清\n弈"
    var theme: Theme
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(-2)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 3).fill(theme.accent))
    }
}

/// 墨白主题：题字上方的发丝饰线（线 · 点 · 朱砂方印 · 点 · 线）
struct OrnamentRow: View {
    var theme: Theme
    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(theme.divider)
                .frame(width: 42, height: 1)
            Spacer().frame(width: 10)
            Circle()
                .fill(theme.divider)
                .frame(width: 3, height: 3)
            Spacer().frame(width: 10)
            Rectangle()
                .fill(theme.accent)
                .frame(width: 6, height: 6)
            Spacer().frame(width: 10)
            Circle()
                .fill(theme.divider)
                .frame(width: 3, height: 3)
            Spacer().frame(width: 10)
            Rectangle()
                .fill(theme.divider)
                .frame(width: 42, height: 1)
        }
        .frame(height: 18)
    }
}

/// 粉彩主题：纸上建筑穹顶
struct DomeMark: View {
    var body: some View {
        VStack(spacing: 3) {
            DomeShape()
                .fill(Color(hex: 0xB7CDB4))
                .frame(width: 80, height: 40)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: 0xD8C9B8))
                .frame(width: 104, height: 5)
        }
    }
}

struct DomeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let shoulder = rect.width / 2
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: shoulder),
                          control: CGPoint(x: rect.midX, y: -shoulder * 0.5))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 单选 / 开关

struct RadioDot: View {
    var checked: Bool
    var theme: Theme
    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.sub, lineWidth: 1.2)
                .frame(width: 18, height: 18)
            if checked {
                Circle().fill(theme.accent).frame(width: 9, height: 9)
            }
        }
        .frame(width: 22, height: 22)
    }
}

struct CheckRow: View {
    var title: String
    var checked: Bool
    var theme: Theme
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RadioDot(checked: checked, theme: theme)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(theme.title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 动作按钮

enum ActionKind { case normal, primary, danger }

struct ThemedActionButton: View {
    var title: String
    var subtitle: String? = nil
    var kind: ActionKind = .normal
    var theme: Theme
    var action: () -> Void

    private var fill: Color {
        if theme.isHara { return .clear }
        switch kind {
        case .primary: return theme.primaryBg
        case .danger: return theme.entryBg[0]
        case .normal: return theme.btnBg
        }
    }

    private var textColor: Color {
        if theme.isHara { return kind == .danger ? theme.dangerText : theme.btnText }
        switch kind {
        case .primary: return theme.primaryText
        case .danger: return theme.dangerText
        case .normal: return theme.btnText
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: theme.isHara ? .regular : .medium, design: .serif))
                if theme.isHara, let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .regular, design: .serif))
                        .foregroundColor(theme.foot)
                        .tracking(1)
                }
            }
            .foregroundColor(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.isHara ? 11 : 12)
            .background(
                RoundedRectangle(cornerRadius: theme.btnRadius)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.btnRadius)
                    .stroke(theme.hairlineList ? Color.clear : borderColor, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(false)
    }

    private var borderColor: Color {
        kind == .danger ? theme.dangerStroke : theme.btnStroke
    }
}

// MARK: - 弹窗

struct DialogScaffold<Content: View>: View {
    var title: String
    var theme: Theme
    var content: Content
    var onDismiss: () -> Void

    init(title: String, theme: Theme, onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.theme = theme
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    if theme.isHara {
                        Rectangle()
                            .fill(theme.accent)
                            .frame(width: 9, height: 9)
                    } else {
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 9, height: 9)
                    }
                    Text(title)
                        .font(.qySerif(18, weight: .bold))
                        .foregroundColor(theme.title)
                        .tracking(1)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 14)

                Hairline(color: theme.dlgLine)
                    .padding(.bottom, 16)

                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 24)
            .background(
                RoundedRectangle(cornerRadius: theme.isHara ? 6 : 20)
                    .fill(theme.windowBg)
            )
            .padding(.horizontal, 26)
        }
    }
}

// MARK: - 滑杆(细线 + accent)

struct ThemedSlider: View {
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var step: Double
    var theme: Theme

    var body: some View {
        Slider(value: value, in: range, step: step)
            .tint(theme.id == .hara ? theme.title : theme.accent)
    }
}

// MARK: - 页面背景

struct PaperBackground: View {
    var theme: Theme
    var body: some View {
        theme.windowBg.ignoresSafeArea()
    }
}

// MARK: - 对局页共用版式（单机 / 联机同源）

/// 单机对局页与联机对局页共用的一套尺寸定义。
///
/// 棋盘边长、动作行行高、左右留白只在这里写一次：联机页不再另写一组数值，
/// 单机页的 `frame(height:)` 也改成引用同一个常量，避免两页再次跑偏。
enum GameLayout {
    /// 页面左右留白（文字行、动作区各 6pt）
    static let columnInset: CGFloat = 6
    /// 棋盘左右留白：0 表示左右直接贴屏幕边缘（与联机页一致）。
    static let boardInset: CGFloat = 0
    /// 单机页棋盘需要向外顶出的距离（= 文字行留白 − 棋盘留白）
    static var boardBleed: CGFloat { columnInset - boardInset }
    /// 动作行行高（单机 actionGrid / reviewGrid 与联机动作区共用）
    static let actionRowHeight: CGFloat = 56
    /// 象棋棋盘高宽比：9 列 × 10 行 → 高 = 宽 × 10/9
    static let xiangqiHeightRatio: CGFloat = 10.0 / 9.0

    /// 棋盘边长 = 可用宽度 − 棋盘左右留白。
    /// 单机页与联机页都引用这一个函数，尺寸不可能再跑偏。
    static func boardSide(availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - boardInset * 2)
    }

    /// 棋盘高度：围棋为正方形，象棋按 10/9 拉高
    static func boardHeight(side: CGFloat, isXiangqi: Bool) -> CGFloat {
        isXiangqi ? side * xiangqiHeightRatio : side
    }

    /// 单机页实际可用的棋盘边长：
    /// 宽度优先铺满（左右贴屏），高度不够时按剩余高度收窄，保证整盘可见、不被刘海/底栏遮挡。
    static func fittedSide(availableWidth: CGFloat,
                           availableHeight: CGFloat,
                           isXiangqi: Bool) -> CGFloat {
        let byWidth = boardSide(availableWidth: availableWidth)
        let byHeight = max(0, availableHeight) / (isXiangqi ? xiangqiHeightRatio : 1)
        return max(0, min(byWidth, byHeight))
    }
}

/// 动作格：单机与联机共用同一份字号 / 行距 / 颜色规则。
struct GameActionCell: View {
    let title: String
    let en: String
    var danger: Bool = false
    var selected: Bool = false
    var primary: Bool = false
    var theme: Theme

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: primary ? .semibold : .regular))
                .foregroundColor(danger ? theme.dangerText
                                 : (selected ? theme.primaryText : (primary ? theme.accent : theme.title)))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if !en.isEmpty {
                Text(en)
                    .font(.system(size: 9))
                    .tracking(1)
                    .foregroundColor(selected ? theme.primaryText.opacity(0.7) : theme.sub)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(selected ? theme.primaryBg : Color.clear)
        .contentShape(Rectangle())
    }
}
