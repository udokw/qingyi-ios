//
//  BanqiRules.swift
//  清弈
//
//  移植自 Android：app/src/main/java/com/sijia/go/net/BanqiRules.java
//  暗棋规则适配器（联机裁决，房主权威用）：封装 BanqiGame，供 LAN 协议调用。
//  暗子身份只由房主掌握；客机通过 flipWith / loadFen 镜像。
//
//  与 Android 的差异（仅结果原因，不改变任何棋规/数值）：
//  Android 的 resultByTimeout / resultByDisconnect 都调用 game.resign()，
//  于是 detail 变成「X方认输」，UI（ResultText）只能显示认输。
//  Swift 侧改用 timeout(seat:) / disconnect(seat:)，并在 result 的 reason 字段
//  输出 "timeout" / "disconnect"，保证文案与原因可区分。
//

import Foundation

/// 落子裁决结果，字段与 Android `GameAdapter.ApplyResult` 对齐。
struct BanqiApplyResult {
    var ok = false
    var code = ""
    var message = ""
    var flip = false
    var x = -1
    var y = -1
    var fx = -1
    var fy = -1
    var tx = -1
    var ty = -1
    /// 翻出 / 移动的棋子编码。
    var piece = 0
    var seat1Color = 0
    var seat2Color = 0
    var captured = 0
    var nextTurn = 0
    var moveNo = 0
    var hash = ""
}

/// 供 UI 显示的最后一手，字段与 Android `GameAdapter.MoveInfo` 对齐。
struct BanqiMoveInfo {
    var seat = 0
    var fx = -1
    var fy = -1
    var tx = -1
    var ty = -1
    var flip = false
    var piece = 0
    var captured = 0
    var text = ""
}

final class BanqiRules {

    static let id = "banqi"
    static let label = "暗棋"

    private(set) var game: BanqiGame

    init() {
        game = BanqiGame()
    }

    var boardSize: Int {
        BanqiGame.rows * BanqiGame.cols
    }

    func reset() {
        game = BanqiGame()
    }

    var turn: Int {
        game.turnSeat
    }

    var moveCount: Int {
        game.plies
    }

    var isOver: Bool {
        game.isOver
    }

    func hash(moveNo: Int) -> String {
        game.positionKey
    }

    func snapshot() -> [String: Any] {
        ["fen": game.fen, "moveNo": game.plies]
    }

    func restore(_ snap: [String: Any]?) -> Bool {
        guard let snap, let fen = snap["fen"] as? String, !fen.isEmpty else {
            return false
        }
        let next = BanqiGame()
        guard next.loadFen(fen) else {
            return false
        }
        game = next
        return true
    }

    // MARK: - 房主裁决

    func apply(seat: Int, move: [String: Any]) -> BanqiApplyResult {
        var r = BanqiApplyResult()
        r.nextTurn = game.turnSeat
        if seat != game.turnSeat {
            r.code = "E_OUT_OF_TURN"
            r.message = "还没轮到这一方"
            return r
        }
        let flip = BanqiRules.flag(move, "flip")
        let x = BanqiRules.number(move, "x")
        let y = BanqiRules.number(move, "y")
        let fx = BanqiRules.number(move, "fx")
        let fy = BanqiRules.number(move, "fy")
        let tx = BanqiRules.number(move, "tx")
        let ty = BanqiRules.number(move, "ty")
        let ok = flip
            ? game.flip(x: x, y: y)
            : game.play(fromX: fx, fromY: fy, toX: tx, toY: ty)
        if !ok {
            r.code = "E_ILLEGAL_MOVE"
            r.message = flip ? "这里不能翻子" : "这一手不能走"
            return r
        }
        let last = game.historySnapshot().first
        r.ok = true
        r.flip = flip
        if flip {
            r.x = x
            r.y = y
        } else {
            r.fx = fx
            r.fy = fy
            r.tx = tx
            r.ty = ty
        }
        if let last {
            r.piece = last.piece
            r.captured = last.captured
        }
        r.seat1Color = game.colorOfSeat(1)
        r.seat2Color = game.colorOfSeat(2)
        r.nextTurn = game.turnSeat
        r.moveNo = game.plies
        r.hash = game.positionKey
        return r
    }

    /// 客机镜像房主的落子；expectedHash 为空表示不校验。
    func applyAck(_ ack: [String: Any]?, moveNo: Int, expectedHash: String?) -> Bool {
        guard let ack else {
            return false
        }
        if moveNo > 0 && game.plies != moveNo - 1 {
            return false
        }
        let flip = BanqiRules.flag(ack, "flip")
        let ok: Bool
        if flip {
            ok = game.flipWith(x: BanqiRules.number(ack, "x"),
                               y: BanqiRules.number(ack, "y"),
                               revealed: BanqiRules.number(ack, "piece", fallback: 0))
        } else {
            ok = game.play(fromX: BanqiRules.number(ack, "fx"),
                           fromY: BanqiRules.number(ack, "fy"),
                           toX: BanqiRules.number(ack, "tx"),
                           toY: BanqiRules.number(ack, "ty"))
        }
        if !ok {
            return false
        }
        return expectedHash == nil || expectedHash!.isEmpty || expectedHash == game.positionKey
    }

    @discardableResult
    func undo(_ count: Int) -> Int {
        var done = 0
        for _ in 0..<count {
            if game.undo() == nil {
                break
            }
            done += 1
        }
        return done
    }

    func movePayload(seat: Int, move: [String: Any], hashBefore: String?) -> [String: Any] {
        var p: [String: Any] = [:]
        let flip = BanqiRules.flag(move, "flip")
        p["flip"] = flip
        if flip {
            p["x"] = BanqiRules.number(move, "x")
            p["y"] = BanqiRules.number(move, "y")
        } else {
            p["fx"] = BanqiRules.number(move, "fx")
            p["fy"] = BanqiRules.number(move, "fy")
            p["tx"] = BanqiRules.number(move, "tx")
            p["ty"] = BanqiRules.number(move, "ty")
        }
        if let hashBefore, !hashBefore.isEmpty {
            p["hashBefore"] = hashBefore
        }
        return p
    }

    /// history 最新在前，与 Android `lastStep()` 一致。
    func lastMove() -> BanqiMoveInfo? {
        guard let m = game.historySnapshot().first else {
            return nil
        }
        var i = BanqiMoveInfo()
        i.seat = m.seat
        i.flip = m.flip
        i.piece = m.piece
        i.fx = m.x
        i.fy = m.y
        if !m.flip {
            i.tx = m.tx
            i.ty = m.ty
        }
        i.captured = m.captured
        i.text = game.notation(m)
        return i
    }

    // MARK: - 结果

    func result() -> [String: Any]? {
        if !game.isOver {
            return nil
        }
        let res = game.result
        let code = res == BanqiGame.resultDraw ? "draw"
            : (res == BanqiGame.red ? "red" : "black")
        let reason: String
        if res == BanqiGame.resultDraw {
            reason = "draw"
        } else {
            let tag = game.endReasonKind.protocolReason
            reason = tag.isEmpty ? "rule" : tag
        }
        return [
            "result": code,
            "detail": game.endReason,
            "reason": reason,
            "moveNo": game.plies
        ]
    }

    func resultByResign(_ resignSeat: Int) -> [String: Any]? {
        game.resign(seat: resignSeat)
        return result()
    }

    func resultByTimeout(_ timeoutSeat: Int) -> [String: Any]? {
        game.timeout(seat: timeoutSeat)
        return result()
    }

    func resultByDisconnect(_ lostSeat: Int) -> [String: Any]? {
        game.disconnect(seat: lostSeat)
        return result()
    }

    // MARK: - 座位 / 颜色

    func colorChar(seat: Int) -> String {
        String(seat)
    }

    func seatFromChar(_ s: String) -> Int {
        if s == "1" { return 1 }
        if s == "2" { return 2 }
        // 兼容旧字段：B 当作先手，W 当作后手
        return s.lowercased() == "w" ? 2 : 1
    }

    func colorName(seat: Int) -> String {
        let color = game.colorOfSeat(seat)
        if color == 0 {
            return seat == BanqiGame.seatFirst ? "先手" : "后手"
        }
        return BanqiGame.colorName(color)
    }

    var supportsPass: Bool {
        false
    }

    var supportsScore: Bool {
        false
    }

    // MARK: - 协议字段解析（兼容 JSON 原生类型与字符串）

    private static func flag(_ dict: [String: Any], _ key: String) -> Bool {
        guard let raw = dict[key] else { return false }
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            let lower = s.lowercased()
            return lower == "true" || lower == "1" || lower == "yes"
        }
        return false
    }

    private static func number(_ dict: [String: Any], _ key: String, fallback: Int = -1) -> Int {
        guard let raw = dict[key] else { return fallback }
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let i = Int(s) { return i }
        return fallback
    }
}

// MARK: - 自检（仅 Debug；Windows 无 Swift 环境，未执行，只保证语法正确）

#if DEBUG
enum BanqiSelfCheck {

    /// 返回空数组表示全部通过。
    static func run() -> [String] {
        var failures: [String] = []
        checkCaptureTable(&failures)
        checkFlipAttribution(&failures)
        checkEndConditions(&failures)
        checkUndo(&failures)
        return failures
    }

    /// 断言版：失败直接崩溃，便于 XCTest / 启动期自检。
    static func assertAll() {
        let failures = run()
        precondition(failures.isEmpty, "BanqiSelfCheck 失败:\n" + failures.joined(separator: "\n"))
    }

    // MARK: 1. 吃子关系全表

    private static func checkCaptureTable(_ failures: inout [String]) {
        let ranks = [7, 6, 5, 4, 3, 2, 1]

        // 规则开关默认值必须与 Android 一致。
        if !BanqiOptions.equalRankCanCapture {
            failures.append("规则开关 equalRankCanCapture 默认应为 true")
        }
        if !BanqiOptions.cannonScreenMayBeHidden {
            failures.append("规则开关 cannonScreenMayBeHidden 默认应为 true")
        }
        if BanqiOptions.cannonCanCaptureByStep {
            failures.append("规则开关 cannonCanCaptureByStep 默认应为 false")
        }
        if BanqiOptions.firstSeat != BanqiGame.seatFirst {
            failures.append("规则开关 firstSeat 默认应为先手")
        }
        if BanqiOptions.drawIdlePlies != BanqiGame.drawIdlePlies {
            failures.append("规则开关 drawIdlePlies 默认应为 30")
        }
        if !BanqiOptions.flipForSeat2 {
            failures.append("规则开关 flipForSeat2 默认应为 true")
        }

        for a in 0..<7 {
            for d in 0..<7 {
                let expected: Bool
                if a == BanqiGame.cannon {
                    // 炮不能走步吃子
                    expected = false
                } else if a == BanqiGame.king && d == BanqiGame.pawn {
                    expected = false
                } else if a == BanqiGame.pawn && d == BanqiGame.king {
                    expected = true
                } else {
                    expected = ranks[a] >= ranks[d]
                }

                let redAttacker = BanqiGame.piece(color: BanqiGame.red, type: a)
                let blackDefender = BanqiGame.piece(color: BanqiGame.black, type: d)
                let actual = BanqiGame.canCaptureByStep(redAttacker, blackDefender)
                if actual != expected {
                    failures.append("吃子表 红\(BanqiGame.pieceName(redAttacker)) 吃 黑\(BanqiGame.pieceName(blackDefender))：期望 \(expected)，实际 \(actual)")
                }

                let blackAttacker = BanqiGame.piece(color: BanqiGame.black, type: a)
                let redDefender = BanqiGame.piece(color: BanqiGame.red, type: d)
                let reversed = BanqiGame.canCaptureByStep(blackAttacker, redDefender)
                if reversed != expected {
                    failures.append("吃子表 黑\(BanqiGame.pieceName(blackAttacker)) 吃 红\(BanqiGame.pieceName(redDefender))：期望 \(expected)，实际 \(reversed)")
                }
            }
        }

        // 空子 / 越界编码一律不能吃。
        if BanqiGame.canCaptureByStep(BanqiGame.empty, BanqiGame.piece(color: BanqiGame.red, type: BanqiGame.king)) {
            failures.append("空格不应能吃子")
        }
        if BanqiGame.canCaptureByStep(BanqiGame.piece(color: BanqiGame.red, type: BanqiGame.king), BanqiGame.empty) {
            failures.append("空目标不应被吃")
        }
        // 同级可互吃。
        let redKing = BanqiGame.piece(color: BanqiGame.red, type: BanqiGame.king)
        let blackKing = BanqiGame.piece(color: BanqiGame.black, type: BanqiGame.king)
        if !BanqiGame.canCaptureByStep(redKing, blackKing) {
            failures.append("同级（將吃將）应可互吃")
        }
        // 卒吃將、將不能吃卒。
        let redPawn = BanqiGame.piece(color: BanqiGame.red, type: BanqiGame.pawn)
        if !BanqiGame.canCaptureByStep(redPawn, blackKing) {
            failures.append("卒应能吃將")
        }
        if BanqiGame.canCaptureByStep(redKing, BanqiGame.piece(color: BanqiGame.black, type: BanqiGame.pawn)) {
            failures.append("將不应能吃卒")
        }
        // 炮不能走步吃子（含炮吃炮）。
        let redCannon = BanqiGame.piece(color: BanqiGame.red, type: BanqiGame.cannon)
        if BanqiGame.canCaptureByStep(redCannon, BanqiGame.piece(color: BanqiGame.black, type: BanqiGame.pawn)) {
            failures.append("炮不应能走步吃子")
        }
    }

    // MARK: 2. 翻子后红黑归属

    private static func checkFlipAttribution(_ failures: inout [String]) {
        // 首翻：翻出黑卒，则先手座位为黑，后手为红。
        var board = blankBoard()
        var up = blankUp()
        let blackPawn = BanqiGame.piece(color: BanqiGame.black, type: BanqiGame.pawn)
        board[0][0] = blackPawn
        up[0][0] = false
        let first = BanqiGame()
        first.setup(encoded: board, up: up, seat1Color: 0,
                    turnSeat: BanqiGame.seatFirst, idle: 0)
        if !first.flip(x: 0, y: 0) {
            failures.append("首翻：翻子失败")
            return
        }
        if first.colorOfSeat(BanqiGame.seatFirst) != BanqiGame.black {
            failures.append("首翻：翻出黑子后先手座位应为黑")
        }
        if first.colorOfSeat(BanqiGame.seatSecond) != BanqiGame.red {
            failures.append("首翻：后手座位应为红")
        }
        if !first.isFaceUp(0, 0) || first.pieceCodeAt(0, 0) != blackPawn {
            failures.append("首翻：翻出后的棋子编码/明面状态不正确")
        }

        // 已定色后再翻：座位颜色不改变。
        board = blankBoard()
        up = blankUp()
        let redKing = BanqiGame.piece(color: BanqiGame.red, type: BanqiGame.king)
        board[0][0] = redKing
        board[1][1] = blackPawn
        let second = BanqiGame()
        second.setup(encoded: board, up: up, seat1Color: BanqiGame.red,
                     turnSeat: BanqiGame.seatFirst, idle: 0)
        if !second.flip(x: 1, y: 1) {
            failures.append("定色后翻子失败")
            return
        }
        if second.colorOfSeat(BanqiGame.seatFirst) != BanqiGame.red
            || second.colorOfSeat(BanqiGame.seatSecond) != BanqiGame.black {
            failures.append("定色后翻出对方颜色的子，不应改变座位归属")
        }
        if second.pieceCodeAt(1, 1) != blackPawn {
            failures.append("定色后翻出的子编码不正确")
        }
    }

    // MARK: 3. 和棋 / 无子可动

    private static func checkEndConditions(_ failures: inout [String]) {
        let redKing = BanqiGame.piece(color: BanqiGame.red, type: BanqiGame.king)
        let blackKing = BanqiGame.piece(color: BanqiGame.black, type: BanqiGame.king)

        // 3a. 连续 30 步无吃子无翻子判和。
        var board = blankBoard()
        var up = blankUp()
        board[0][0] = redKing
        board[3][7] = blackKing
        up[0][0] = true
        up[3][7] = true
        let idleGame = BanqiGame()
        idleGame.setup(encoded: board, up: up, seat1Color: BanqiGame.red,
                       turnSeat: BanqiGame.seatFirst, idle: BanqiGame.drawIdlePlies - 1)
        if !idleGame.play(fromX: 0, fromY: 0, toX: 1, toY: 0) {
            failures.append("无进展和棋：走子失败")
        } else {
            if idleGame.result != BanqiGame.resultDraw {
                failures.append("无进展和棋：结果应为和棋")
            }
            if idleGame.endReasonKind != .idleDraw {
                failures.append("无进展和棋：结束原因应为 idleDraw")
            }
            if !idleGame.endReason.contains("30") {
                failures.append("无进展和棋：文案应包含阈值 30")
            }
        }

        // 3b. 无子可动判负（黑方无子）。
        board = blankBoard()
        up = blankUp()
        board[0][0] = redKing
        up[0][0] = true
        let noMove = BanqiGame()
        noMove.setup(encoded: board, up: up, seat1Color: BanqiGame.red,
                     turnSeat: BanqiGame.seatSecond, idle: 0)
        noMove.refreshEnd()
        if noMove.result != BanqiGame.red {
            failures.append("无子可动：红方应获胜")
        }
        if noMove.endReasonKind != .noLegalMove(seat: BanqiGame.seatSecond) {
            failures.append("无子可动：结束原因应为 noLegalMove(黑方座位)")
        }
        if !noMove.endReason.contains("无子可动") {
            failures.append("无子可动：文案应包含「无子可动」")
        }

        // 3c. 双方均无子可动判和。
        board = blankBoard()
        up = blankUp()
        let mutual = BanqiGame()
        mutual.setup(encoded: board, up: up, seat1Color: 0,
                     turnSeat: BanqiGame.seatFirst, idle: 0)
        mutual.refreshEnd()
        if mutual.result != BanqiGame.resultDraw {
            failures.append("双方无子可动：应判和")
        }
        if mutual.endReasonKind != .mutualNoMoveDraw {
            failures.append("双方无子可动：结束原因应为 mutualNoMoveDraw")
        }

        // 3d. 同一局面出现三次判和。
        board = blankBoard()
        up = blankUp()
        board[0][0] = redKing
        board[3][7] = blackKing
        up[0][0] = true
        up[3][7] = true
        let repeatGame = BanqiGame()
        repeatGame.setup(encoded: board, up: up, seat1Color: BanqiGame.red,
                         turnSeat: BanqiGame.seatFirst, idle: 0)
        let cycle = [(0, 0, 1, 0), (7, 3, 6, 3), (1, 0, 0, 0), (6, 3, 7, 3)]
        for round in 0..<2 {
            for (idx, mv) in cycle.enumerated() {
                if !repeatGame.play(fromX: mv.0, fromY: mv.1, toX: mv.2, toY: mv.3) {
                    failures.append("三次重复局面：第 \(round * cycle.count + idx + 1) 手走子失败")
                    break
                }
            }
        }
        if repeatGame.result != BanqiGame.resultDraw {
            failures.append("三次重复局面：应判和")
        }
        if repeatGame.endReasonKind != .repeatDraw {
            failures.append("三次重复局面：结束原因应为 repeatDraw")
        }
    }

    // MARK: 4. 悔棋回滚

    private static func checkUndo(_ failures: inout [String]) {
        // 4a. 吃子后悔棋：棋盘、明面、轮次、计数、结果、局面键全部回滚。
        var board = blankBoard()
        var up = blankUp()
        let redRook = BanqiGame.piece(color: BanqiGame.red, type: BanqiGame.rook)
        let blackPawn = BanqiGame.piece(color: BanqiGame.black, type: BanqiGame.pawn)
        board[0][0] = redRook
        board[0][1] = blackPawn
        up[0][0] = true
        up[0][1] = true
        let captureGame = BanqiGame()
        captureGame.setup(encoded: board, up: up, seat1Color: BanqiGame.red,
                          turnSeat: BanqiGame.seatFirst, idle: 0)
        let keyBefore = captureGame.positionKey
        if !captureGame.play(fromX: 0, fromY: 0, toX: 0, toY: 1) {
            failures.append("悔棋：吃子走法失败")
        } else {
            if captureGame.pieceCodeAt(0, 0) != BanqiGame.empty
                || captureGame.pieceCodeAt(0, 1) != redRook {
                failures.append("悔棋：吃子后的棋盘不正确")
            }
            guard let undone = captureGame.undo() else {
                failures.append("悔棋：undo 返回 nil")
                return
            }
            if undone.piece != redRook || undone.captured != blackPawn {
                failures.append("悔棋：undo 返回的着法记录不正确")
            }
            if captureGame.pieceCodeAt(0, 0) != redRook || captureGame.pieceCodeAt(0, 1) != blackPawn {
                failures.append("悔棋：棋盘未回滚")
            }
            if !captureGame.isFaceUp(0, 0) || !captureGame.isFaceUp(0, 1) {
                failures.append("悔棋：明面状态未回滚")
            }
            if captureGame.turnSeat != BanqiGame.seatFirst
                || captureGame.plies != 0
                || captureGame.idlePlies != 0
                || captureGame.isOver {
                failures.append("悔棋：轮次/计数/终局状态未回滚")
            }
            if captureGame.positionKey != keyBefore {
                failures.append("悔棋：局面键未回滚")
            }
        }

        // 4b. 首翻后悔棋：暗子身份、明面、座位颜色、终局状态全部回滚。
        board = blankBoard()
        up = blankUp()
        board[2][2] = blackPawn
        let flipGame = BanqiGame()
        flipGame.setup(encoded: board, up: up, seat1Color: 0,
                       turnSeat: BanqiGame.seatFirst, idle: 0)
        let flipKeyBefore = flipGame.positionKey
        if !flipGame.flip(x: 2, y: 2) {
            failures.append("悔棋：翻子失败")
        } else {
            if flipGame.colorOfSeat(BanqiGame.seatFirst) != BanqiGame.black
                || flipGame.colorOfSeat(BanqiGame.seatSecond) != BanqiGame.red {
                failures.append("悔棋：翻子后的座位颜色不正确")
            }
            if flipGame.undo() == nil {
                failures.append("悔棋：翻子后 undo 返回 nil")
                return
            }
            if flipGame.colorOfSeat(BanqiGame.seatFirst) != 0
                || flipGame.colorOfSeat(BanqiGame.seatSecond) != 0 {
                failures.append("悔棋：座位颜色未回滚")
            }
            if flipGame.isFaceUp(2, 2) {
                failures.append("悔棋：翻子后应恢复为暗子")
            }
            if flipGame.pieceCodeAt(2, 2) != blackPawn {
                failures.append("悔棋：暗子身份未回滚")
            }
            if flipGame.turnSeat != BanqiGame.seatFirst
                || flipGame.plies != 0
                || flipGame.isOver {
                failures.append("悔棋：轮次/终局状态未回滚")
            }
            if flipGame.positionKey != flipKeyBefore {
                failures.append("悔棋：局面键未回滚")
            }
        }

        // 4c. 无历史时 undo 返回 nil。
        if BanqiGame().undo() != nil {
            failures.append("悔棋：无历史时应返回 nil")
        }

        // 4d. 超时 / 认输必须是两个不同的结束原因（Android 侧混用 resign）。
        let resignGame = BanqiGame()
        resignGame.setup(encoded: blankBoard(), up: blankUp(), seat1Color: BanqiGame.red,
                         turnSeat: BanqiGame.seatFirst, idle: 0)
        resignGame.resign(seat: BanqiGame.seatFirst)
        if resignGame.endReasonKind != .resign(seat: BanqiGame.seatFirst) {
            failures.append("认输：结束原因应为 resign")
        }
        if resignGame.endReason.contains("超时") {
            failures.append("认输：文案不应包含「超时」")
        }

        let timeoutGame = BanqiGame()
        timeoutGame.setup(encoded: blankBoard(), up: blankUp(), seat1Color: BanqiGame.red,
                          turnSeat: BanqiGame.seatFirst, idle: 0)
        timeoutGame.timeout(seat: BanqiGame.seatFirst)
        if timeoutGame.endReasonKind != .timeout(seat: BanqiGame.seatFirst) {
            failures.append("超时：结束原因应为 timeout")
        }
        if !timeoutGame.endReason.contains("超时") {
            failures.append("超时：文案应包含「超时」")
        }
    }

    // MARK: 工具

    private static func blankBoard() -> [[Int]] {
        Array(repeating: Array(repeating: BanqiGame.empty, count: BanqiGame.cols),
              count: BanqiGame.rows)
    }

    private static func blankUp() -> [[Bool]] {
        Array(repeating: Array(repeating: false, count: BanqiGame.cols),
              count: BanqiGame.rows)
    }
}
#endif
