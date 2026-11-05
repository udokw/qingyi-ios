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
            .font(.system(size: size / 3.0, weight: .medium, design: .serif))
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
            .font(.system(size: 10, weight: .medium, design: .serif))
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
            .font(.system(size: 11, weight: .medium, design: .serif))
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
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: 9, height: 9)
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .serif))
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
