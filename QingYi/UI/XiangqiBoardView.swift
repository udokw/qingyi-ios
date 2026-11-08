import SwiftUI

/// 中国象棋棋盘: 9 列 × 10 行, 楚河汉界, 九宫斜线, 炮位标记
struct XiangqiBoardView: View {
    var board: [[XiangqiGame.Piece?]]
    var selection: GoPoint?
    var hints: [GoPoint]
    var lastMove: XiangqiGame.Move?
    var theme: Theme
    var onTap: (Int, Int) -> Void
    var onDrag: (Int, Int, Int, Int) -> Void
    /// 客机执黑时按坐标镜像翻转棋盘（x→cols-1-x, y→rows-1-y），
    /// 与 Android `XiangqiBoardView.px()/py()` 一致。
    /// 只镜像位置、不旋转画布，所以棋子与「楚河汉界」的文字天然正立。
    var flipped: Bool = false

    private let cols = XiangqiGame.cols
    private let rows = XiangqiGame.rows

    var body: some View {
        Canvas { context, canvasSize in
            let metrics = layout(in: canvasSize)
            drawBoard(&context, metrics)

            for y in 0..<rows {
                for x in 0..<cols {
                    guard y < board.count, x < board[y].count, let p = board[y][x] else { continue }
                    drawPiece(&context, piece: p, point: GoPoint(x: x, y: y), metrics: metrics)
                }
            }

            if let last = lastMove {
                ring(&context, point: last.to, metrics: metrics, color: theme.marker, radius: 0.48)
            }

            if let selection {
                let c = center(of: selection, metrics)
                let r = metrics.cell * 0.5
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(theme.accent), lineWidth: 2.2)
            }

            for hint in hints {
                let c = center(of: hint, metrics)
                let r = metrics.cell * 0.14
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                             with: .color(theme.accent.opacity(0.85)))
            }
        }
        .background(theme.boardBg)
        .aspectRatio(9.0 / 10.0, contentMode: .fit)
        .contentShape(Rectangle())
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let m = layout(in: geo.size)
                                let dx = value.translation.width
                                let dy = value.translation.height
                                let start = gridPoint(at: value.startLocation, metrics: m)
                                let end = gridPoint(at: value.location, metrics: m)
                                if dx * dx + dy * dy > 64 {
                                    if let from = start, let to = end {
                                        onDrag(from.x, from.y, to.x, to.y)
                                    }
                                } else if let p = end {
                                    onTap(p.x, p.y)
                                }
                            }
                    )
            }
        )
    }

    // MARK: - 绘制

    private struct Metrics {
        var cell: CGFloat
        var origin: CGPoint
    }

    private func layout(in size: CGSize) -> Metrics {
        let margin = size.width * 0.05
        let cell = (size.width - margin * 2) / CGFloat(cols - 1)
        let origin = CGPoint(x: margin,
                             y: (size.height - cell * CGFloat(rows - 1)) / 2)
        return Metrics(cell: cell, origin: origin)
    }

    /// 逻辑坐标 → 屏幕坐标的镜像映射；`flipped` 时为 180° 点位镜像。
    /// 自反：再调用一次即还原，因此也能用于把落点还原成逻辑坐标。
    private func render(_ p: GoPoint) -> GoPoint {
        flipped ? GoPoint(x: cols - 1 - p.x, y: rows - 1 - p.y) : p
    }

    /// 逻辑坐标对应的像素中心（已应用镜像）。
    private func center(of p: GoPoint, _ m: Metrics) -> CGPoint {
        pixel(render(p), m)
    }

    /// 未镜像的像素中心，仅用于命中测试的几何换算。
    private func pixel(_ p: GoPoint, _ m: Metrics) -> CGPoint {
        CGPoint(x: m.origin.x + CGFloat(p.x) * m.cell,
                y: m.origin.y + CGFloat(p.y) * m.cell)
    }

    private func drawBoard(_ context: inout GraphicsContext, _ m: Metrics) {
        let left = m.origin.x
        let top = m.origin.y
        let width = CGFloat(cols - 1) * m.cell
        let height = CGFloat(rows - 1) * m.cell
        let right = left + width

        // 外框
        let frame = CGRect(x: left - m.cell * 0.28, y: top - m.cell * 0.28,
                           width: width + m.cell * 0.56, height: height + m.cell * 0.56)
        context.stroke(Path(roundedRect: frame, cornerRadius: 3),
                       with: .color(theme.boardLine.opacity(0.55)), lineWidth: 1.4)

        var lines = Path()
        // 横线
        for y in 0..<rows {
            let py = top + CGFloat(y) * m.cell
            lines.move(to: CGPoint(x: left, y: py))
            lines.addLine(to: CGPoint(x: right, y: py))
        }
        // 竖线: 边线贯通, 中间在河界断开
        for x in 0..<cols {
            let px = left + CGFloat(x) * m.cell
            if x == 0 || x == cols - 1 {
                lines.move(to: CGPoint(x: px, y: top))
                lines.addLine(to: CGPoint(x: px, y: top + height))
            } else {
                lines.move(to: CGPoint(x: px, y: top))
                lines.addLine(to: CGPoint(x: px, y: top + CGFloat(4) * m.cell))
                lines.move(to: CGPoint(x: px, y: top + CGFloat(5) * m.cell))
                lines.addLine(to: CGPoint(x: px, y: top + height))
            }
        }
        // 九宫斜线
        for palaceTop in [0, 7] {
            lines.move(to: CGPoint(x: left + 3 * m.cell, y: top + CGFloat(palaceTop) * m.cell))
            lines.addLine(to: CGPoint(x: left + 5 * m.cell, y: top + CGFloat(palaceTop + 2) * m.cell))
            lines.move(to: CGPoint(x: left + 5 * m.cell, y: top + CGFloat(palaceTop) * m.cell))
            lines.addLine(to: CGPoint(x: left + 3 * m.cell, y: top + CGFloat(palaceTop + 2) * m.cell))
        }
        context.stroke(lines, with: .color(theme.boardLine.opacity(0.9)), lineWidth: 0.8)

        // 炮位与兵位标记
        let marks: [GoPoint] = [
            GoPoint(x: 1, y: 2), GoPoint(x: 7, y: 2), GoPoint(x: 1, y: 7), GoPoint(x: 7, y: 7),
            GoPoint(x: 0, y: 3), GoPoint(x: 2, y: 3), GoPoint(x: 4, y: 3), GoPoint(x: 6, y: 3), GoPoint(x: 8, y: 3),
            GoPoint(x: 0, y: 6), GoPoint(x: 2, y: 6), GoPoint(x: 4, y: 6), GoPoint(x: 6, y: 6), GoPoint(x: 8, y: 6)
        ]
        for p in marks {
            drawPositionMark(&context, at: center(of: p, m), cell: m.cell)
        }

        // 楚河汉界：红方视角「左楚河、右汉界」；黑方视角镜像成「左汉界、右楚河」，
        // 文字本身不旋转，始终正向可读。
        let riverY = top + CGFloat(4.5) * m.cell
        let riverFont = Font.qySerif(m.cell * 0.62)
        let chuX = left + width * (flipped ? 0.72 : 0.28)
        let hanX = left + width * (flipped ? 0.28 : 0.72)
        context.draw(Text("楚 河")
                        .font(riverFont)
                        .foregroundColor(theme.boardLine.opacity(0.85)),
                     at: CGPoint(x: chuX, y: riverY), anchor: .center)
        context.draw(Text("汉 界")
                        .font(riverFont)
                        .foregroundColor(theme.boardLine.opacity(0.85)),
                     at: CGPoint(x: hanX, y: riverY), anchor: .center)

        // 棋盘外框
        context.stroke(Path(CGRect(origin: .zero, size: CGSize(width: left * 2 + width,
                                                              height: top * 2 + height)).insetBy(dx: 0.5, dy: 0.5)),
                       with: .color(theme.boardLine.opacity(0.7)), lineWidth: 1)
    }

    private func drawPositionMark(_ context: inout GraphicsContext, at c: CGPoint, cell: CGFloat) {
        let gap = cell * 0.12
        let len = cell * 0.18
        var path = Path()
        for dx in [-1.0, 1.0] {
            for dy in [-1.0, 1.0] {
                let ox = c.x + CGFloat(dx) * (gap + len * 0.5)
                let oy = c.y + CGFloat(dy) * (gap + len * 0.5)
                // 只画靠近边线的一臂
                path.move(to: CGPoint(x: ox - CGFloat(dx) * len * 0.5, y: oy))
                path.addLine(to: CGPoint(x: ox + CGFloat(dx) * len * 0.5, y: oy))
                path.move(to: CGPoint(x: ox, y: oy - CGFloat(dy) * len * 0.5))
                path.addLine(to: CGPoint(x: ox, y: oy + CGFloat(dy) * len * 0.5))
            }
        }
        context.stroke(path, with: .color(theme.boardLine.opacity(0.55)), lineWidth: 0.8)
    }

    private func drawPiece(_ context: inout GraphicsContext, piece: XiangqiGame.Piece, point: GoPoint, metrics m: Metrics) {
        let c = center(of: point, m)
        let r = m.cell * 0.43
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)

        context.fill(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)),
                     with: .color(Color.black.opacity(0.10)))
        context.fill(Path(ellipseIn: rect),
                     with: .radialGradient(
                        Gradient(colors: [Color(hex: 0xFCF4E2), Color(hex: 0xEDE0C4)]),
                        center: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.35),
                        startRadius: 1, endRadius: r * 1.5))

        let side: Color = piece.color == .red ? Color(hex: 0xB03A26) : Color(hex: 0x2A2A2A)
        context.stroke(Path(ellipseIn: rect), with: .color(side.opacity(0.9)), lineWidth: 1.1)
        context.stroke(Path(ellipseIn: rect.insetBy(dx: 4, dy: 4)),
                       with: .color(side.opacity(0.28)), lineWidth: 0.7)

        context.draw(Text(XiangqiGame.pieceName(piece))
                        .font(.qySerif(m.cell * 0.62, weight: .bold))
                        .foregroundColor(side),
                     at: c, anchor: .center)
    }

    private func ring(_ context: inout GraphicsContext, point: GoPoint, metrics m: Metrics,
                      color: Color, radius: CGFloat) {
        let c = center(of: point, m)
        let r = m.cell * radius
        context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                       with: .color(color), lineWidth: 1.6)
    }

    // MARK: - 坐标

    private func gridPoint(at location: CGPoint, metrics m: Metrics) -> GoPoint? {
        guard m.cell > 0 else { return nil }
        let x = Int(round((location.x - m.origin.x) / m.cell))
        let y = Int(round((location.y - m.origin.y) / m.cell))
        guard x >= 0, x < cols, y >= 0, y < rows else { return nil }
        let c = pixel(GoPoint(x: x, y: y), m)
        let dx = location.x - c.x
        let dy = location.y - c.y
        guard dx * dx + dy * dy <= (m.cell * 0.65) * (m.cell * 0.65) else { return nil }
        // 屏幕格点 → 逻辑坐标（`render` 自反，翻转时即反向镜像）
        return render(GoPoint(x: x, y: y))
    }
}
