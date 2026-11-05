import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

extension Font {
    /// 安卓端使用 serif 字体（宋体），iOS 指定宋体以贴近
    static func qySerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Songti SC", size: size).weight(weight)
    }
}

enum ThemeID: String, CaseIterable, Identifiable {
    case hara
    case monument

    var id: String { rawValue }
    var name: String { self == .hara ? "墨白" : "粉彩" }
}

/// 双主题: 墨白(和纸/墨色/朱红/发丝线)  粉彩(柔粉彩/圆角卡片/珊瑚 accent)
struct Theme {
    let id: ThemeID
    let windowBg: Color
    let title: Color
    let sub: Color
    let foot: Color
    let accent: Color
    let entryBg: [Color]
    let entryRadius: CGFloat
    let entryTitle: Color
    let entryDesc: Color
    let prefixColor: Color
    let hairlineList: Bool
    let prefixes: [String]
    let btnBg: Color
    let btnText: Color
    let btnStroke: Color
    let btnRadius: CGFloat
    let primaryBg: Color
    let primaryText: Color
    let dangerText: Color
    let dangerStroke: Color
    let boardBg: Color
    let boardLine: Color
    let marker: Color
    let divider: Color
    let dlgLine: Color

    var isHara: Bool { id == .hara }
    var name: String { id.name }

    static func of(_ id: ThemeID) -> Theme {
        id == .hara ? .hara : .monument
    }

    static let monument = Theme(
        id: .monument,
        windowBg: Color(hex: 0xF6F1EA),
        title: Color(hex: 0x3E3A36),
        sub: Color(hex: 0x9A9186),
        foot: Color(hex: 0xB0A79B),
        accent: Color(hex: 0xE8846B),
        entryBg: [Color(hex: 0xF5DFD8), Color(hex: 0xDEE7DC), Color(hex: 0xF3E9CF)],
        entryRadius: 20,
        entryTitle: Color(hex: 0x3E3A36),
        entryDesc: Color(hex: 0x8A8072),
        prefixColor: Color(hex: 0xB0A79B),
        hairlineList: false,
        prefixes: ["01", "02", "03"],
        btnBg: Color(hex: 0xEFE7DA),
        btnText: Color(hex: 0x3E3A36),
        btnStroke: Color.clear,
        btnRadius: 22,
        primaryBg: Color(hex: 0xB7CDB4),
        primaryText: Color(hex: 0x2F3A2E),
        dangerText: Color(hex: 0xB06A55),
        dangerStroke: Color(hex: 0xD8C9B8),
        boardBg: Color(hex: 0xF3E7CE),
        boardLine: Color(hex: 0xA08B6D),
        marker: Color(hex: 0xE8846B),
        divider: Color.clear,
        dlgLine: Color(hex: 0xE3D9C8)
    )

    static let hara = Theme(
        id: .hara,
        windowBg: Color(hex: 0xF7F4ED),
        title: Color(hex: 0x1A1A1A),
        sub: Color(hex: 0x6B665C),
        foot: Color(hex: 0x9A9384),
        accent: Color(hex: 0xC73E2B),
        entryBg: [Color(hex: 0xF7F4ED), Color(hex: 0xF7F4ED), Color(hex: 0xF7F4ED)],
        entryRadius: 0,
        entryTitle: Color(hex: 0x1A1A1A),
        entryDesc: Color(hex: 0x8A8474),
        prefixColor: Color(hex: 0xC73E2B),
        hairlineList: true,
        prefixes: ["壹", "贰", "叁"],
        btnBg: Color.clear,
        btnText: Color(hex: 0x1A1A1A),
        btnStroke: Color(hex: 0xCFC8B8),
        btnRadius: 2,
        primaryBg: Color(hex: 0x1A1A1A),
        primaryText: Color(hex: 0xF7F4ED),
        dangerText: Color(hex: 0xC73E2B),
        dangerStroke: Color(hex: 0xCFC8B8),
        boardBg: Color(hex: 0xE3B771),
        boardLine: Color(hex: 0x3A3226),
        marker: Color(hex: 0xC73E2B),
        divider: Color(hex: 0xDDD6C4),
        dlgLine: Color(hex: 0xDDD6C4)
    )
}
