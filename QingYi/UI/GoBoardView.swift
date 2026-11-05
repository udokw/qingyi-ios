import SwiftUI

/// 围棋棋盘: 木纹底 + 交叉线 + 星位 + 提子标记 + 形势归属
struct GoBoardView: View {
    var board: [[GoColor]]
    var size: Int
    var lastMove: GoPoint?
    var ko: GoPoint?
    var territory: [[Int]]?
    var theme: Theme
    var onTap: (Int, Int) -> Void

    var body: some View {
        Canvas { context, canvasSize in
            let width = min(canvasSize.width, canvasSize.height)
            guard size > 1 else { return }
            let margin = width * 0.042
            let cell = (width - margin * 2) / CGFloat(size - 1)

            // 形势: 地域小块
            if let territory {
                for y in 0..<min(size, territory.count) {
                    for x in 0..<min(size, territory[y].count) {
                        let owner = territory[y][x]
                        guard owner != 0 else { continue }
                        let color = owner == 1 ? Color.black.opacity(0.35) : Color.white.opacity(0.55)
                        let block = cell * 0.28
                        let rect = CGRect(x: margin + CGFloat(x) * cell - block / 2,
                                          y: margin + CGFloat(y) * cell - block / 2,
                                          width: block, height: block)
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }

            // 棋线
            var lines = Path()
            for i in 0..<size {
                let pos = margin + CGFloat(i) * cell
                lines.move(to: CGPoint(x: margin, y: pos))
                lines.addLine(to: CGPoint(x: width - margin, y: pos))
                lines.move(to: CGPoint(x: pos, y: margin))
                lines.addLine(to: CGPoint(x: pos, y: width - margin))
            }
            context.stroke(lines, with: .color(theme.boardLine.opacity(0.9)), lineWidth: 0.8)

            // 星位
            let starPoints = starCoordinates(size: size)
            for p in starPoints {
                let c = CGPoint(x: margin + CGFloat(p.x) * cell, y: margin + CGFloat(p.y) * cell)
                let r: CGFloat = cell * 0.09
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(theme.boardLine))
            }

            // 棋子
            for y in 0..<min(size, board.count) {
                for x in 0..<min(size, board[y].count) {
                    let stone = board[y][x]
                    guard stone != .empty else { continue }
                    drawStone(context: &context, center: CGPoint(x: margin + CGFloat(x) * cell,
                                                                 y: margin + CGFloat(y) * cell),
                              radius: cell * 0.47, black: stone == .black)
                }
            }

            // 劫点
            if let ko {
                let c = CGPoint(x: margin + CGFloat(ko.x) * cell, y: margin + CGFloat(ko.y) * cell)
                let r = cell * 0.15
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(theme.marker.opacity(0.9)), lineWidth: 1.2)
            }

            // 最后一手
            if let last = lastMove {
                let c = CGPoint(x: margin + CGFloat(last.x) * cell, y: margin + CGFloat(last.y) * cell)
                let stone = last.y < board.count && last.x < board[last.y].count ? board[last.y][last.x] : .empty
                if stone != .empty {
                    let color: Color = stone == .black ? .white : theme.marker
                    let r = cell * 0.47 * 0.5
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.95)), lineWidth: 3)
                }
            }

            // 棋盘外框
            context.stroke(Path(CGRect(origin: .zero, size: canvasSize).insetBy(dx: 0.5, dy: 0.5)),
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
                                if let p = intersection(at: value.location, width: min(geo.size.width, geo.size.height)) {
                                    onTap(p.x, p.y)
                                }
                            }
                    )
            }
        )
    }

    private func drawStone(context: inout GraphicsContext, center: CGPoint, radius: CGFloat, black: Bool) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        let path = Path(ellipseIn: rect)
        if black {
            context.fill(path, with: .radialGradient(
                Gradient(colors: [Color(hex: 0x6E6E6E), Color(hex: 0x101010)]),
                center: CGPoint(x: center.x - radius * 0.35, y: center.y - radius * 0.4),
                startRadius: 0.5, endRadius: radius * 1.4))
        } else {
            context.fill(path, with: .radialGradient(
                Gradient(colors: [Color.white, Color(hex: 0xD8D3C8)]),
                center: CGPoint(x: center.x - radius * 0.35, y: center.y - radius * 0.4),
                startRadius: 0.5, endRadius: radius * 1.5))
            context.stroke(path, with: .color(Color.black.opacity(0.18)), lineWidth: 0.6)
        }
    }

    private func intersection(at location: CGPoint, width: CGFloat) -> GoPoint? {
        guard size > 1, width > 0 else { return nil }
        let margin = width * 0.05
        let cell = (width - margin * 2) / CGFloat(size - 1)
        let x = Int(round((location.x - margin) / cell))
        let y = Int(round((location.y - margin) / cell))
        guard x >= 0, x < size, y >= 0, y < size else { return nil }
        let px = margin + CGFloat(x) * cell
        let py = margin + CGFloat(y) * cell
        guard hypot(location.x - px, location.y - py) <= cell * 0.7 else { return nil }
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
        if coords.count == 3 {
            for y in coords {
                for x in coords {
                    if x == 9 && y == 9 { continue }
                    points.append(GoPoint(x: x, y: y))
                }
            }
            points.append(GoPoint(x: 9, y: 9))
        } else if coords.count == 2 {
            for y in coords {
                for x in coords { points.append(GoPoint(x: x, y: y)) }
            }
        }
        return points
    }
}
