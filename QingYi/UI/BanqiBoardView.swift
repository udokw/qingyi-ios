import SwiftUI

/// 暗棋棋盘：4 行 × 8 列铺满整宽，暗子只画背面，明子按红黑着色。
/// 棋盘线、装饰内框、选中/可走提示的数值与 Android `BanqiBoardView` 保持一致。
/// 座位 2 可将整盘 180° 翻转显示，触摸回调始终返回逻辑坐标。
struct BanqiBoardView: View {
    var board: [[Int]]
    var faceUp: [[Bool]]
    var selection: GoPoint?
    var legalTargets: [GoPoint]
    var flipped: Bool
    var theme: Theme
    var interactive: Bool = true
    var onTap: (Int, Int) -> Void
    var onLongPress: () -> Void

    private static let rows = 4
    private static let cols = 8
    private static let faceFill = Color(hex: 0xF6EBD8)
    private static let redInk = Color(hex: 0xA93226)
    private static let blackInk = Color(hex: 0x1A1A1A)
    private static let redGlyph = Color(hex: 0xC0553F)
    private static let blackGlyph = Color(hex: 0x3E3A36)
    /// 暗子背面的细纹理方向（单位向量）。
    private static let texture: [CGPoint] = [
        CGPoint(x: 1, y: 0), CGPoint(x: 0.7071, y: 0.7071),
        CGPoint(x: 0, y: 1), CGPoint(x: -0.7071, y: 0.7071),
        CGPoint(x: -1, y: 0), CGPoint(x: -0.7071, y: -0.7071),
        CGPoint(x: 0, y: -1), CGPoint(x: 0.7071, y: -0.7071)
    ]

    var body: some View {
        GeometryReader { geo in
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            guard w > 0, h > 0 else { return }

            let cellX = (w * 0.9) / CGFloat(Self.cols)
            let cellY = (h * 0.9) / CGFloat(Self.rows)
            let cell = min(cellX, cellY)
            let originX = (w - cell * CGFloat(Self.cols)) / 2
            let originY = (h - cell * CGFloat(Self.rows)) / 2

            let left = originX
            let top = originY
            let right = originX + cell * CGFloat(Self.cols)
            let bottom = originY + cell * CGFloat(Self.rows)

            // 装饰内框：外扩 0.28 格、圆角 3、1.4 线、alpha 140
            let off = cell * 0.28
            let innerRect = CGRect(x: left - off, y: top - off,
                                   width: (right - left) + off * 2,
                                   height: (bottom - top) + off * 2)
            context.stroke(Path(roundedRect: innerRect, cornerRadius: 3),
                           with: .color(theme.boardLine.opacity(140.0 / 255.0)), lineWidth: 1.4)

            // 棋盘外描边：1pt、alpha 179、贴画布边缘
            context.stroke(Path(CGRect(origin: .zero, size: canvasSize).insetBy(dx: 0.5, dy: 0.5)),
                           with: .color(theme.boardLine.opacity(179.0 / 255.0)), lineWidth: 1)

            // 格线 1.6
            var grid = Path()
            for r in 0...Self.rows {
                let y = top + CGFloat(r) * cell
                grid.move(to: CGPoint(x: left, y: y))
                grid.addLine(to: CGPoint(x: right, y: y))
            }
            for c in 0...Self.cols {
                let x = left + CGFloat(c) * cell
                grid.move(to: CGPoint(x: x, y: top))
                grid.addLine(to: CGPoint(x: x, y: bottom))
            }
            context.stroke(grid, with: .color(theme.boardLine), lineWidth: 1.6)

            // 外框加粗 3.2
            context.stroke(Path(CGRect(x: left, y: top, width: right - left, height: bottom - top)),
                           with: .color(theme.boardLine), lineWidth: 3.2)

            // 棋子
            for y in 0..<Self.rows {
                for x in 0..<Self.cols {
                    guard y < board.count, x < board[y].count else { continue }
                    let p = board[y][x]
                    guard p != 0 else { continue }
                    let up = y < faceUp.count && x < faceUp[y].count && faceUp[y][x]
                    drawPiece(context: &context,
                              center: CGPoint(x: px(x, cell: cell, originX: originX),
                                              y: py(y, cell: cell, originY: originY)),
                              code: p, faceUp: up, cell: cell)
                }
            }

            // 选中与可走提示
            let stoneR = cell * 0.425
            if let sel = selection {
                let c = CGPoint(x: px(sel.x, cell: cell, originX: originX),
                                y: py(sel.y, cell: cell, originY: originY))
                let r = stoneR + cell * 0.06
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(theme.accent), lineWidth: 3.2)
            }
            for target in legalTargets {
                let c = CGPoint(x: px(target.x, cell: cell, originX: originX),
                                y: py(target.y, cell: cell, originY: originY))
                let occupied = target.y < board.count && target.x < board[target.y].count
                    && board[target.y][target.x] != 0
                if occupied {
                    let r = cell * 0.48
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(theme.accent), lineWidth: 3)
                } else {
                    let r = cell * 0.14
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(theme.marker.opacity(110.0 / 255.0)))
                }
            }
        }
        .background(theme.boardBg)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            guard interactive, let p = cellAt(location, size: geo.size) else { return }
            onTap(p.x, p.y)
        }
        .onLongPressGesture(minimumDuration: 0.3) {
            onLongPress()
        }
        }
    }

    // MARK: - 绘制

    private func drawPiece(context: inout GraphicsContext, center: CGPoint,
                           code: Int, faceUp: Bool, cell: CGFloat) {
        let r = cell * 0.425
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        context.fill(Path(ellipseIn: rect), with: .color(Self.faceFill))

        if !faceUp {
            // 暗子：只画背面，不泄漏任何身份
            context.stroke(Path(ellipseIn: rect),
                           with: .color(theme.boardLine.opacity(200.0 / 255.0)), lineWidth: 2.2)
            let inner = r * 0.82
            let innerRect = CGRect(x: center.x - inner, y: center.y - inner,
                                   width: inner * 2, height: inner * 2)
            context.stroke(Path(ellipseIn: innerRect),
                           with: .color(theme.boardLine.opacity(70.0 / 255.0)), lineWidth: 1)
            var tex = Path()
            for dir in Self.texture {
                tex.move(to: CGPoint(x: center.x + dir.x * r * 0.38,
                                     y: center.y + dir.y * r * 0.38))
                tex.addLine(to: CGPoint(x: center.x + dir.x * r * 0.62,
                                        y: center.y + dir.y * r * 0.62))
            }
            context.stroke(tex, with: .color(theme.boardLine.opacity(45.0 / 255.0)), lineWidth: 0.9)
            return
        }

        let red = code <= 7
        let ink = red ? Self.redInk : Self.blackInk
        let glyph = red ? Self.redGlyph : Self.blackGlyph
        context.stroke(Path(ellipseIn: rect), with: .color(ink), lineWidth: 2.2)
        let inner = r * 0.82
        let innerRect = CGRect(x: center.x - inner, y: center.y - inner,
                               width: inner * 2, height: inner * 2)
        context.stroke(Path(ellipseIn: innerRect), with: .color(ink.opacity(70.0 / 255.0)),
                       lineWidth: 1)

        let name = BanqiGame.pieceName(code)
        context.draw(
            Text(name)
                .font(.system(size: cell * 0.42, weight: .bold, design: .serif))
                .foregroundColor(glyph),
            at: center,
            anchor: .center
        )
    }

    // MARK: - 坐标

    private func px(_ x: Int, cell: CGFloat, originX: CGFloat) -> CGFloat {
        let sx = flipped ? Self.cols - 1 - x : x
        return originX + (CGFloat(sx) + 0.5) * cell
    }

    private func py(_ y: Int, cell: CGFloat, originY: CGFloat) -> CGFloat {
        let sy = flipped ? Self.rows - 1 - y : y
        return originY + (CGFloat(sy) + 0.5) * cell
    }

    /// 用与绘制完全相同的一套 origin/cell 定位，留白区域不响应。
    private func cellAt(_ location: CGPoint, size: CGSize) -> GoPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let cell = min((size.width * 0.9) / CGFloat(Self.cols),
                       (size.height * 0.9) / CGFloat(Self.rows))
        guard cell > 0 else { return nil }
        let originX = (size.width - cell * CGFloat(Self.cols)) / 2
        let originY = (size.height - cell * CGFloat(Self.rows)) / 2
        let sx = Int(floor((location.x - originX) / cell))
        let sy = Int(floor((location.y - originY) / cell))
        guard sx >= 0, sx < Self.cols, sy >= 0, sy < Self.rows else { return nil }
        return GoPoint(x: flipped ? Self.cols - 1 - sx : sx,
                       y: flipped ? Self.rows - 1 - sy : sy)
    }
}
