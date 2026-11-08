import SwiftUI

/// 五子棋棋盘：复用 19 路围棋棋盘的尺寸、外描边、木色与双主题配色。
/// 额外绘制获胜五连线与 AI 提示点。数值全部照抄 Android `GomokuBoardView`。
struct GomokuBoardView: View {
    var board: [[Int]]
    var size: Int
    var lastMove: GoPoint?
    var winLine: (GoPoint, GoPoint)?
    var hint: GoPoint?
    var theme: Theme
    var onTap: (Int, Int) -> Void

    var body: some View {
        Canvas { context, canvasSize in
            let width = min(canvasSize.width, canvasSize.height)
            guard size > 1 else { return }
            // 与围棋盘一致：最外线贴边，只留最外侧棋子半径 + 2px 抗锯齿余量
            let margin = (0.47 * width / CGFloat(size - 1) + 2) / (1 + 0.94 / CGFloat(size - 1))
            let cell = (width - margin * 2) / CGFloat(size - 1)

            // 网格
            var lines = Path()
            for i in 0..<size {
                let p = margin + CGFloat(i) * cell
                lines.move(to: CGPoint(x: margin, y: p))
                lines.addLine(to: CGPoint(x: width - margin, y: p))
                lines.move(to: CGPoint(x: p, y: margin))
                lines.addLine(to: CGPoint(x: p, y: width - margin))
            }
            context.stroke(lines, with: .color(theme.boardLine), lineWidth: 2)

            // 外沿加粗
            var outer = Path()
            outer.move(to: CGPoint(x: margin, y: margin))
            outer.addLine(to: CGPoint(x: width - margin, y: margin))
            outer.move(to: CGPoint(x: margin, y: width - margin))
            outer.addLine(to: CGPoint(x: width - margin, y: width - margin))
            outer.move(to: CGPoint(x: margin, y: margin))
            outer.addLine(to: CGPoint(x: margin, y: width - margin))
            outer.move(to: CGPoint(x: width - margin, y: margin))
            outer.addLine(to: CGPoint(x: width - margin, y: width - margin))
            context.stroke(outer, with: .color(theme.boardLine), lineWidth: 4)

            // 星位（19 路同围棋）
            for p in starCoordinates(size: size) {
                let c = CGPoint(x: margin + CGFloat(p.x) * cell, y: margin + CGFloat(p.y) * cell)
                let r = cell * 0.09
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(theme.boardLine))
            }

            // 棋子
            let stoneR = cell * 0.47
            for y in 0..<min(size, board.count) {
                for x in 0..<min(size, board[y].count) {
                    let v = board[y][x]
                    guard v != 0 else { continue }
                    drawStone(context: &context,
                              center: CGPoint(x: margin + CGFloat(x) * cell,
                                              y: margin + CGFloat(y) * cell),
                              radius: stoneR, black: v == 1)
                }
            }

            // 获胜五连高亮
            if let winLine {
                var path = Path()
                path.move(to: CGPoint(x: margin + CGFloat(winLine.0.x) * cell,
                                      y: margin + CGFloat(winLine.0.y) * cell))
                path.addLine(to: CGPoint(x: margin + CGFloat(winLine.1.x) * cell,
                                         y: margin + CGFloat(winLine.1.y) * cell))
                context.stroke(path,
                               with: .color(theme.marker.opacity(220.0 / 255.0)),
                               style: StrokeStyle(lineWidth: max(3, cell * 0.10), lineCap: .round))
            }

            // AI 提示点：外圈 + 中心点
            if let hint, hint.x >= 0, hint.y >= 0, hint.x < size, hint.y < size,
               hint.y < board.count, hint.x < board[hint.y].count, board[hint.y][hint.x] == 0 {
                let c = CGPoint(x: margin + CGFloat(hint.x) * cell, y: margin + CGFloat(hint.y) * cell)
                let r = stoneR * 0.72
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(theme.marker),
                               lineWidth: max(2, cell * 0.06))
                let dot = stoneR * 0.16
                let dotRect = CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(theme.marker))
            }

            // 最后落子标记
            if let last = lastMove, last.x >= 0, last.y >= 0,
               last.x < size, last.y < size,
               last.y < board.count, last.x < board[last.y].count,
               board[last.y][last.x] != 0 {
                let c = CGPoint(x: margin + CGFloat(last.x) * cell, y: margin + CGFloat(last.y) * cell)
                let color: Color = board[last.y][last.x] == 1 ? .white : theme.marker
                let r = stoneR * 0.5
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 3)
            }

            // 外描边：1pt 线，内缩 0.5pt，70% 不透明
            context.stroke(Path(CGRect(origin: .zero, size: CGSize(width: width, height: width))
                .insetBy(dx: 0.5, dy: 0.5)),
                           with: .color(theme.boardLine.opacity(0.7)), lineWidth: 1)
        }
        .background(theme.boardBg)
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                if let p = intersection(at: value.location,
                                                        width: min(geo.size.width, geo.size.height)) {
                                    onTap(p.x, p.y)
                                }
                            }
                    )
            }
        )
    }

    private func drawStone(context: inout GraphicsContext, center: CGPoint,
                           radius: CGFloat, black: Bool) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        let path = Path(ellipseIn: rect)
        let highlight = CGPoint(x: center.x - radius / 3, y: center.y - radius / 3)
        if black {
            context.fill(path, with: .radialGradient(
                Gradient(colors: [Color(hex: 0x5A5A5A), Color(hex: 0x141414)]),
                center: highlight, startRadius: 0.5, endRadius: radius))
        } else {
            context.fill(path, with: .radialGradient(
                Gradient(colors: [Color.white, Color(hex: 0xC8C8C8)]),
                center: highlight, startRadius: 0.5, endRadius: radius))
        }
    }

    private func intersection(at location: CGPoint, width: CGFloat) -> GoPoint? {
        guard size > 1, width > 0 else { return nil }
        let margin = (0.47 * width / CGFloat(size - 1) + 2) / (1 + 0.94 / CGFloat(size - 1))
        let cell = (width - margin * 2) / CGFloat(size - 1)
        let x = Int(round((location.x - margin) / cell))
        let y = Int(round((location.y - margin) / cell))
        guard x >= 0, x < size, y >= 0, y < size else { return nil }
        return GoPoint(x: x, y: y)
    }

    private func starCoordinates(size: Int) -> [GoPoint] {
        let coords: [Int]
        switch size {
        case 19: coords = [3, 9, 15]
        case 13: coords = [3, 6, 9]
        case 9: coords = [3, 5]
        default: coords = []
        }
        var points: [GoPoint] = []
        for y in coords {
            for x in coords { points.append(GoPoint(x: x, y: y)) }
        }
        return points
    }
}
